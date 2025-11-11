//SPDX-License-Identifier: MIT 

pragma solidity 0.8.30;

/*///////////////////////
        Imports
///////////////////////*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
    @title KipuBank
    @author Ariel Rodríguez
    @notice TP final del módulo 4 del curso de Ethereum de EthKipu
    @notice Es una simulación de banco con depósitos, extracción y conversión de divisas
*/
contract KipuBank is Ownable{

    /*//////////////////////
            Tipos
    //////////////////////*/
    using SafeERC20 for IERC20;

    /*//////////////////////
            Variables
    //////////////////////*/
    /// @notice variable constante para almacenar el latido (heartbeat) del Data Feed
    uint16 constant ORACLE_HEARTBEAT = 3600;
    /// @notice variable constante para almacenar el factor de decimales
    uint256 constant DECIMAL_FACTOR = 1*(10**20);

    /// @notice variable para almacenar la dirección del Chainlink Feed
    AggregatorV3Interface public s_feeds;

    /// @notice Factory de Uniswap V2 para obtener pares
    IUniswapV2Factory public immutable FACTORY;

    /*//////////////////////
            Mappings
    //////////////////////*/
    /// @notice Mapping que almacena el balance de tokens ERC20 de cada cuenta 
    mapping (address user => mapping (address token => uint256 amount)) s_balances;
    /// @notice Mapping que almacena la cantidad de depósitos de tokens ERC20 de cada cuenta
    mapping (address user => mapping (address token => uint32 counter)) s_deposits;
    /// @notice Mapping que almacena la cantidad de extracciones de tokens ERC20  de cada cuenta
    mapping (address user => mapping (address token => uint32 amount)) s_withdrawals;
    
    /// @notice Límite de balance por cuenta
    uint32 public immutable s_bankCap;
    /// @notice Límite de extracción por cuenta
    uint32 public immutable s_withdrawLimit;

    /// @notice Evento emitido al depositar con éxito
    event Deposited(address from, uint amount);
    /// @notice Evento emitido al extraer con éxito
    event Extracted(address to, uint amount);
    /// @notice Evento emitido al depositar USDC con éxito
    event ERC20Deposited(address from, address tokenAddress, uint amount);
    /// @notice Evento emitido al extraer USDC con éxito
    event ERC20Extracted(address to, address tokenAddress, uint amount);
    /// @notice Evento emitido al extraer USDC con éxito
    event ChainlinkFeedUpdated(AggregatorV3Interface oldFeed, AggregatorV3Interface newFeed);
    /// @notice Evento emitido al ejecutar un swap por UniSwap
    event SwapModule_SwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Error emitido cuando se intenta depositar una cantidad inválida (=0 o >bankCap)
    error DepositNotAllowed(address to, uint amount);
    /// @notice Error emitido cuando se intenta extraer una cantidad inválda (<=0, >saldo, >límite)
    error ExtractionNotAllowed(address to, uint amount);
    /// @notice Error emitido cuando falla una extracción
    error ExtractionReverted(address to, uint amount, bytes errorData);
    /// @notice Error emitido cuando se intenta depositar una cantidad inválida de un token ERC20 (=0)
    error ERC20DepositNotAllowed(address to, address tokenAddress, uint amount);
    /// @notice Error emitido cuando se intenta extraer una cantidad inválda de un token ERC20 (<=0, >saldo)
    error ERC20ExtractionNotAllowed(address to, address tokenAddress, uint amount);
    /// @notice Error emitido cuando falla el oráculo
    error OracleCompromised();
    /// @notice Error emitido cuando la última actualización del oráculo supera el heartbeat
    error StalePrice();
    /// @notice Error emitido cuando se intenta swapear una cantidad insuficiente
    error SwapModule_InsufficientOutputAmount();
    /// @notice Error emitido cuando se intenta swapear un token sin liquidez
    error SwapModule_InsufficientLiquidity();
    /// @notice Error emitido cuando se intenta swapear un par que no existe
    error SwapModule_PairDoesNotExist();
    /// @notice Error emitido cuando se intenta swapear con una dirección inválida
    error SwapModule_InvalidAddress();
    /// @notice Error emitido cuando se intenta swapear una cantidad inválida
    error SwapModule_InvalidAmount();

    /*//////////////////////////
            Modificadores
    //////////////////////////*/
    /**
        @notice Valida que ambas direcciones no sean cero y sean diferentes
        @param tokenA Primera dirección a validar
        @param tokenB Segunda dirección a validar
    */
    modifier validTokenAddresses(address tokenA, address tokenB) {
        if (tokenA == address(0) || tokenB == address(0))
            revert SwapModule_InvalidAddress();
        if (tokenA == tokenB)
            revert SwapModule_InvalidAddress();
        _;
    }
    /**
        @notice Valida que la cantidad sea mayor que cero
        @param amount Cantidad a validar
    */
    modifier validAmount(uint256 amount) {
        if (amount == 0)
            revert SwapModule_InvalidAmount();
        _;
    }
    /**
        @notice Valida que el par de tokens exista en el factory
        @param tokenA Primer token
        @param tokenB Segundo token
    */
    modifier pairExists(address tokenA, address tokenB) {
        address pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0))
            revert SwapModule_PairDoesNotExist();
        _;
    }

    /**
        @notice Constructor que recibe el bankCap como parámetro
        @param _bankCap es el máximo que podría tener el contrato en total
        @param _feed es el feed para conversión de monedas
        @param _factory es la dirección de contrato de UniSwap
    */
    constructor(uint32 _bankCap, uint32 _withdrawLimit, address _feed, address _factory) Ownable(msg.sender) {
        s_bankCap = _bankCap;
        s_withdrawLimit = _withdrawLimit;
        FACTORY = IUniswapV2Factory(_factory);
        s_feeds = AggregatorV3Interface(_feed);
    }

    /*//////////////////////
            Útiles
    //////////////////////*/
    /**
        *@notice Función interna para realizar la conversión de decimales de ETH a USD
        *@param _ethAmount La cantidad de ETH a ser convertida
        *@return convertedAmount_ El resultado del cálculo.
    */
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

    /**
        *@notice Función para consultar el precio en USD del ETH
        *@return ethUSDPrice_ El precio provisto por el oráculo.
    */
    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_feeds.latestRoundData();

        require(ethUSDPrice != 0, OracleCompromised());
        require((block.timestamp - updatedAt) > ORACLE_HEARTBEAT, StalePrice());

        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    /**
        *@notice Función para actualizar el Chainlink Price Feed
        *@param _feed La nueva dirección del Price Feed
        *@dev Sólo puede ser llamada por el propietario
    */
    function setFeeds(address _feed) external onlyOwner {
        emit ChainlinkFeedUpdated(s_feeds, AggregatorV3Interface(_feed));

        s_feeds = AggregatorV3Interface(_feed);
    }

    /*//////////////////
            Eth
    //////////////////*/    

    /**
        *@notice Función receive para manejar depósitos directos
		*@notice Esto garantiza la consistencia con las interacciones del contrato
    */
    receive() external payable {
        depositEth();
    }

    /**
        *@notice Función para hacer un depósito
		*@notice Sólo se puede depositar un valor >0 y <=bankCap
    */
    function depositEth() public payable {
        require(msg.value > 0, DepositNotAllowed(msg.sender,msg.value));
        require(msg.value+s_balances[msg.sender][address(0)] <= s_bankCap, DepositNotAllowed(msg.sender,msg.value));

        s_balances[msg.sender][address(0)] += msg.value;
        s_deposits[msg.sender][address(0)]++;
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
        *@notice Función para hacer un depósito
		*@dev Sólo se puede depositar un valor >0 y <=bankCap
        *@param _amount Cantidad que se quiere extraer. Debe ser <= al balance y al límite de extracción
    */
    function withdrawEth(uint _amount) public {
        require(_amount > 0, ExtractionNotAllowed(msg.sender, _amount));
        require(_amount <= s_balances[msg.sender][address(0)], ExtractionNotAllowed(msg.sender, _amount));
        require(_amount <= s_withdrawLimit, ExtractionNotAllowed(msg.sender, _amount));

        s_balances[msg.sender][address(0)] -= _amount;
        s_withdrawals[msg.sender][address(0)]++;
        
        transferEth(_amount);
        
        emit Extracted(msg.sender, _amount);        
    }

    /**
        *@notice Función privada que transfiere la cantidad pedida por la extracción
		*@dev Nadie puede acceder a esta función excepto ESTE contrato
        *@param _amount Cantidad a transferir
    */
    function transferEth(uint _amount) private {
        (bool success, bytes memory errorData) = msg.sender.call{value: _amount}("");
        require(success, ExtractionReverted(msg.sender,_amount,errorData));
    }

    /*//////////////////
            ERC20
    //////////////////*/

    /**
         *@notice Función externa para recibir depósitos de tokens ERC20
         *@notice Emite un evento cuando la transacción es exitosa.
         *@param _tokenAddress La dirección del contrato del token a depositar
         *@param _amount La cantidad a depositar de USDC
     */
    function depositERC20(address _tokenAddress, uint256 _amount) external {
        require(_amount > 0, DepositNotAllowed(msg.sender,_amount));
        s_balances[msg.sender][_tokenAddress] += _amount;
        s_deposits[msg.sender][_tokenAddress]++;

        emit ERC20Deposited(msg.sender, _tokenAddress, _amount);

        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
        *@notice Función pública para ver el balance que uno mismo tiene de un token ERC20 específico
        *@param _tokenAddress La dirección del contrato del token a consultar
    */
    function getERC20Balance(address _tokenAddress) external view returns(uint balance_) {
        balance_ = s_balances[msg.sender][_tokenAddress];
    }

    /**
        *@notice Función pública para ver la cantidad de depósitos que uno hizo de un token ERC20 específico
        *@param _tokenAddress La dirección del contrato del token a consultar
    */
    function getERC20Deposits(address _tokenAddress) external view returns(uint deposits_) {
        deposits_ = s_deposits[msg.sender][_tokenAddress];
    }

    /**
        *@notice Función pública para ver la cantidad de extracciones que uno hizo de un token ERC20 específico
        *@param _tokenAddress La dirección del contrato del token a consultar
    */
    function getERC20Withdrawals(address _tokenAddress) external view returns(uint withdrawals_) {
        withdrawals_ = s_withdrawals[msg.sender][_tokenAddress];
    }

    /**
        *@notice Función para hacer un depósito
		*@dev Sólo se puede depositar un valor >0 y <=bankCap
        *@param _tokenAddress La dirección del contrato del token a extraer
        *@param _amount Cantidad que se quiere extraer. Debe ser <= al balance y al límite de extracción
    */
    function withdrawERC20(address _tokenAddress, uint _amount) public {
        require(_amount > 0, ERC20ExtractionNotAllowed(msg.sender, _tokenAddress, _amount));
        require(_amount <= s_balances[msg.sender][_tokenAddress], ERC20ExtractionNotAllowed(msg.sender, _tokenAddress, _amount));

        s_balances[msg.sender][_tokenAddress] -= _amount;
        s_withdrawals[msg.sender][_tokenAddress]++;
        
        transferERC20(_tokenAddress, _amount);
        
        emit ERC20Extracted(msg.sender, _tokenAddress, _amount);        
    }

    /**
        *@notice Función privada que transfiere la cantidad pedida por la extracción
		*@dev Nadie puede acceder a esta función excepto ESTE contrato
        *@param _tokenAddress La dirección del contrato del token a transferir
        *@param _amount Cantidad a transferir
    */
    function transferERC20(address _tokenAddress, uint _amount) private {
        IERC20(_tokenAddress).safeTransferFrom(address(this), msg.sender, _amount);
    }

    /*//////////////////////
            Uniswap
    //////////////////////*/

    /**
     * @notice Función para ejecutar swaps de inputs exactos en Uniswap V2
     * @notice Los outputs pueden variar según el valor mínimo amountOutMin
     * @param tokenIn La dirección del token de entrada
     * @param tokenOut La dirección del token de salida
     * @param amountIn La cantidad a intercambiar
     * @param amountOutMin La cantidad mínima aceptada después de un swap
     * @dev Esta función sigue las mejores prácticas de Uniswap V2
     * @return amountOut cantidad de tokens recibidos
     */
    function swapExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        external
        validTokenAddresses(tokenIn, tokenOut)
        validAmount(amountIn)
        pairExists(tokenIn, tokenOut)
        returns (uint256 amountOut)
    {
        address pair = FACTORY.getPair(tokenIn, tokenOut);

        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();

        address token0 = IUniswapV2Pair(pair).token0();
        bool token0IsTokenIn = token0 == tokenIn;

        uint256 amountOutExpected = getAmountOut(amountIn, token0IsTokenIn ? reserve0 : reserve1, token0IsTokenIn ? reserve1 : reserve0);

        if (amountOutExpected < amountOutMin) {
            revert SwapModule_InsufficientOutputAmount();
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        uint256 amount0Out;
        uint256 amount1Out;
        if (token0IsTokenIn) {
            amount0Out = 0;
            amount1Out = amountOutExpected;
        } else {
            amount0Out = amountOutExpected;
            amount1Out = 0;
        }

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;

        if (amountOut < amountOutMin) {
            revert SwapModule_InsufficientOutputAmount();
        }

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapModule_SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
    }

    /**
     * @notice Función auxiliar para calcular la cantidad de salida
     * @param amountIn Cantidad de entrada
     * @param reserveIn Reserva del token de entrada
     * @param reserveOut Reserva del token de salida
     * @return amountOut Cantidad calculada de salida
     * @dev Implementa la fórmula AMM de Uniswap V2: amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut ) public pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            revert SwapModule_InsufficientLiquidity();
        }

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        amountOut = numerator / denominator;
    }
    
    /**
     * @notice Función para obtener el par de tokens
     * @param tokenA Primer token
     * @param tokenB Segundo token
     * @return pair Dirección del par
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return FACTORY.getPair(tokenA, tokenB);
    }

    /*//////////////////
            Otras
    //////////////////*/

    /**
        *@notice Función pública para ver el balance de ETH que uno mismo tiene
    */
    function getBalance() external view returns(uint balance_) {
        balance_ = s_balances[msg.sender][address(0)];
    }

    /**
        *@notice Función pública para ver el balance de ETH que uno mismo tiene en USD
    */
    function getBalanceInUSD() external view returns(uint balance_) {
        balance_ = convertEthInUSD(s_balances[msg.sender][address(0)]);
    }

    /**
        *@notice Función pública para ver la cantidad de depósitos de ETH que uno hizo
    */
    function getDeposits() external view returns(uint deposits_) {
        deposits_ = s_deposits[msg.sender][address(0)];
    }

    /**
        *@notice Función pública para ver la cantidad de extracciones de ETH que uno hizo
    */
    function getWithdrawals() external view returns(uint withdrawals_) {
        withdrawals_ = s_withdrawals[msg.sender][address(0)];
    }
}