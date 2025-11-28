// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*///////////////////////
        Imports
///////////////////////*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
    @title KipuBankV3
    @author Ariel Rodríguez (adaptado)
    @notice Versión mejorada que convierte cualquier token soportado por Uniswap V2 a USDC al depositar.
*/
contract KipuBankV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////
            Constantes / tipos
    //////////////////////*/
    uint16  constant ORACLE_HEARTBEAT = 3600;
    uint256 constant DECIMAL_FACTOR   = 1*(10**20);

    /*//////////////////////
            State
    //////////////////////*/
    AggregatorV3Interface public s_feeds;

    /// Uniswap
    IUniswapV2Factory public immutable FACTORY;
    IUniswapV2Router02 public immutable ROUTER;

    /// USDC token (almacén final)
    address public immutable s_USDC;
    /// WETH address (obtenible por ROUTER.WETH())

    /// Balances por usuario por token (seguimos usando mapping token => amount)
    mapping (address user => mapping (address token => uint256 amount)) s_balances;
    mapping (address user => mapping (address token => uint32 counter)) s_deposits;
    mapping (address user => mapping (address token => uint32 amount)) s_withdrawals;

    /// límite total (ahora uint256 para no ser restrictivo)
    uint256 public immutable s_bankCap;
    uint256 public immutable s_withdrawLimit;

    /// trackeo total en USDC (para respetar bankCap)
    uint256 public s_totalUSDC;

    /*//////////////////////
            Eventos & Errores
    //////////////////////*/
    event Deposited(address from, uint amount);
    event Extracted(address to, uint amount);
    event ERC20Deposited(address from, address tokenAddress, uint amount);
    event ERC20Extracted(address to, address tokenAddress, uint amount);
    event ChainlinkFeedUpdated(AggregatorV3Interface oldFeed, AggregatorV3Interface newFeed);
    event SwapModule_SwapExecuted(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error DepositNotAllowed(address to, uint amount);
    error ExtractionNotAllowed(address to, uint amount);
    error ExtractionReverted(address to, uint amount, bytes errorData);
    error ERC20DepositNotAllowed(address to, address tokenAddress, uint amount);
    error ERC20ExtractionNotAllowed(address to, address tokenAddress, uint amount);
    error OracleCompromised();
    error StalePrice();
    error SwapModule_InsufficientOutputAmount();
    error SwapModule_InsufficientLiquidity();
    error SwapModule_PairDoesNotExist();
    error SwapModule_InvalidAddress();
    error SwapModule_InvalidAmount();
    error BankCapExceeded(uint256 attempted, uint256 available);

    /*//////////////////////////
            Modificadores
    //////////////////////////*/
    modifier validTokenAddresses(address tokenA, address tokenB) {
        if (tokenA == address(0) || tokenB == address(0))
            revert SwapModule_InvalidAddress();
        if (tokenA == tokenB)
            revert SwapModule_InvalidAddress();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0)
            revert SwapModule_InvalidAmount();
        _;
    }

    modifier pairExists(address tokenA, address tokenB) {
        address pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0))
            revert SwapModule_PairDoesNotExist();
        _;
    }

    /**
        @param _bankCap máximo en USDC que puede almacenar el bank (en unidades token USDC)
        @param _withdrawLimit límite de extracción (en la misma unidad que uses)
        @param _feed address chainlink
        @param _factory Uniswap V2 factory
        @param _router Uniswap V2 router
        @param _usdc USDC token address
    */
    constructor(
        uint256 _bankCap,
        uint256 _withdrawLimit,
        address _feed,
        address _factory,
        address _router,
        address _usdc
    ) Ownable(msg.sender) {
        // Validaciones básicas
        require(_bankCap > 0, "bankCap=0");
        require(_withdrawLimit > 0, "withdrawLimit=0");
        require(_feed != address(0) && _factory != address(0) && _router != address(0) && _usdc != address(0), "zero address");

        s_bankCap = _bankCap;
        s_withdrawLimit = _withdrawLimit;
        FACTORY = IUniswapV2Factory(_factory);
        ROUTER = IUniswapV2Router02(_router);
        s_feeds = AggregatorV3Interface(_feed);
        s_USDC = _usdc;
    }

    /*//////////////////////
            Útiles / Oráculo
    //////////////////////*/
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_feeds.latestRoundData();

        if (ethUSDPrice == 0) revert OracleCompromised();

        // CORRECCIÓN: si la última actualización está demasiado vieja -> StalePrice
        // require (tiempo transcurrido) <= ORACLE_HEARTBEAT
        if ((block.timestamp - updatedAt) > ORACLE_HEARTBEAT) revert StalePrice();

        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    function setFeeds(address _feed) external onlyOwner {
        emit ChainlinkFeedUpdated(s_feeds, AggregatorV3Interface(_feed));
        s_feeds = AggregatorV3Interface(_feed);
    }

    /*//////////////////
            ETH
    //////////////////*/

    receive() external payable {
        depositEth();
    }

    /**
        @notice Ahora depositEth convierte ETH -> USDC vía Uniswap y acredita USDC.
        @dev Se respeta el bankCap antes de actualizar balance y se protege con nonReentrant.
    */
    function depositEth() public payable nonReentrant {
        if (msg.value == 0) revert DepositNotAllowed(msg.sender, msg.value);

        address weth = ROUTER.WETH();
        address[] memory path;
        path[0] = weth;
        path[1] = s_USDC;

        // comprobar que el par exista: WETH/USDC
        address pair = FACTORY.getPair(weth, s_USDC);
        if (pair == address(0)) revert SwapModule_PairDoesNotExist();

        // obtener amounts esperados para tener amountOut estimado
        uint256[] memory amountsOut = ROUTER.getAmountsOut(msg.value, path);
        uint256 amountOutExpected = amountsOut[amountsOut.length - 1];

        // comprobar bankCap (importante: s_totalUSDC + amountOutExpected <= s_bankCap)
        if (s_totalUSDC + amountOutExpected > s_bankCap) revert BankCapExceeded(s_totalUSDC + amountOutExpected, s_bankCap - s_totalUSDC);

        // ejecutar swap: swapExactETHForTokens
        // usamos amountOutExpected como amountOutMin (puedes ajustar slippage según necesidad)
        ROUTER.swapExactETHForTokens{value: msg.value}(amountOutExpected, path, address(this), block.timestamp);

        // actualizar estados: acreditamos USDC en el balance del usuario
        s_balances[msg.sender][s_USDC] += amountOutExpected;
        s_deposits[msg.sender][s_USDC]++; // contabilizamos deposito en USDC (aunque vino de ETH)
        s_totalUSDC += amountOutExpected;

        emit Deposited(msg.sender, msg.value);
        emit ERC20Deposited(msg.sender, s_USDC, amountOutExpected);
        emit SwapModule_SwapExecuted(msg.sender, weth, s_USDC, msg.value, amountOutExpected);
    }

    /**
        @notice Extraer USDC (u otro token si está acreditado). Mantenemos la función pero la lógica
                sigue siendo: disminuir balance y transferir token.
        @dev Añadí nonReentrant y validaciones.
    */
    function withdrawEth(uint _amount) public nonReentrant {
        // En esta versión guardamos USDC como token final.
        // Si quieres permitir "retirar ETH" que provenga de USDC podríamos agregar swap inverso (no pedido).
        // Mantengo la función para compatibilidad: si alguien tuviera balance en address(0) (ETH) se procesa.
        require(_amount > 0, ExtractionNotAllowed(msg.sender, _amount));
        require(_amount <= s_balances[msg.sender][address(0)], ExtractionNotAllowed(msg.sender, _amount));
        require(_amount <= s_withdrawLimit, ExtractionNotAllowed(msg.sender, _amount));

        s_balances[msg.sender][address(0)] -= _amount;
        s_withdrawals[msg.sender][address(0)]++;

        transferEth(_amount);

        emit Extracted(msg.sender, _amount);
    }

    function transferEth(uint _amount) private {
        (bool success, bytes memory errorData) = msg.sender.call{value: _amount}("");
        require(success, ExtractionReverted(msg.sender,_amount,errorData));
    }

    /*//////////////////
            ERC20
    //////////////////*/

    /**
         @notice depositERC20 ahora:
                 - si _tokenAddress == USDC: transfiere y acredita directamente (respeta bankCap)
                 - si otro token: intercambia token -> USDC (direct pair token-USDC requerido) y acredita en USDC
    */
    function depositERC20(address _tokenAddress, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ERC20DepositNotAllowed(msg.sender, _tokenAddress, _amount);

        // Si ya es USDC: transfer y check bankCap
        if (_tokenAddress == s_USDC) {
            // comprobar bank cap
            if (s_totalUSDC + _amount > s_bankCap) revert BankCapExceeded(s_totalUSDC + _amount, s_bankCap - s_totalUSDC);

            // transferir USDC desde el usuario al contrato
            IERC20(s_USDC).safeTransferFrom(msg.sender, address(this), _amount);

            // actualizar balances en USDC
            s_balances[msg.sender][s_USDC] += _amount;
            s_deposits[msg.sender][s_USDC]++;
            s_totalUSDC += _amount;

            emit ERC20Deposited(msg.sender, s_USDC, _amount);
            return;
        }

        // Si no es USDC: necesitamos swap directo token -> USDC vía Router (requerimos par directo)
        // Validar que exista par token/USDC
        address pair = FACTORY.getPair(_tokenAddress, s_USDC);
        if (pair == address(0)) revert SwapModule_PairDoesNotExist();

        // Transfer token desde usuario al contrato
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);

        // aprobar router
        IERC20(_tokenAddress).approve(address(ROUTER), 0);
        IERC20(_tokenAddress).approve(address(ROUTER), _amount);

        address[] memory path;
        path[0] = _tokenAddress;
        path[1] = s_USDC;

        uint256[] memory amountsOut = ROUTER.getAmountsOut(_amount, path);
        uint256 amountOutExpected = amountsOut[amountsOut.length - 1];

        // comprobar bankCap
        if (s_totalUSDC + amountOutExpected > s_bankCap) {
            // revertamos la allowance y retornamos token al usuario (mejor revert para simplicidad)
            // revert con info
            revert BankCapExceeded(s_totalUSDC + amountOutExpected, s_bankCap - s_totalUSDC);
        }

        // ejecutar swapExactTokensForTokens
        // usamos amountOutExpected como amountOutMin para forzar que se cumpla la estimación actual
        ROUTER.swapExactTokensForTokens(_amount, amountOutExpected, path, address(this), block.timestamp);

        // ahora el contrato tiene USDC; lo acreditamos al usuario
        uint256 receivedUSDC = IERC20(s_USDC).balanceOf(address(this));
        // Para seguridad: calculamos cuánto aumentó en USDC debido a este swap comparando con s_totalUSDC
        // Pero s_totalUSDC incluye todo, así guardamos el delta tomando la diferencia entre balance del contrato USDC y (s_totalUSDC - sum de otros user balances no posible)
        // Simplificación: leer saldo USDC del contrato y confiar en amountOutExpected (por la llamada previa).
        // Acreditamos amountOutExpected al usuario:
        s_balances[msg.sender][s_USDC] += amountOutExpected;
        s_deposits[msg.sender][s_USDC]++;
        s_totalUSDC += amountOutExpected;

        emit ERC20Deposited(msg.sender, _tokenAddress, _amount);
        emit SwapModule_SwapExecuted(msg.sender, _tokenAddress, s_USDC, _amount, amountOutExpected);
    }

    function getERC20Balance(address _tokenAddress) external view returns(uint balance_) {
        balance_ = s_balances[msg.sender][_tokenAddress];
    }

    function getERC20Deposits(address _tokenAddress) external view returns(uint deposits_) {
        deposits_ = s_deposits[msg.sender][_tokenAddress];
    }

    function getERC20Withdrawals(address _tokenAddress) external view returns(uint withdrawals_) {
        withdrawals_ = s_withdrawals[msg.sender][_tokenAddress];
    }

    /**
        @notice withdrawERC20: extrae cualquier token del que tengas balance registrado (incluido USDC)
        @dev Uso de nonReentrant y validaciones. Corrijo transferencia para usar safeTransfer.
    */
    function withdrawERC20(address _tokenAddress, uint _amount) public nonReentrant {
        if (_amount == 0) revert ERC20ExtractionNotAllowed(msg.sender, _tokenAddress, _amount);
        if (_amount > s_balances[msg.sender][_tokenAddress]) revert ERC20ExtractionNotAllowed(msg.sender, _tokenAddress, _amount);

        // si es USDC, actualizamos el total USDC almacenado
        if (_tokenAddress == s_USDC) {
            s_totalUSDC -= _amount;
        }

        s_balances[msg.sender][_tokenAddress] -= _amount;
        s_withdrawals[msg.sender][_tokenAddress]++;

        transferERC20(_tokenAddress, _amount);

        emit ERC20Extracted(msg.sender, _tokenAddress, _amount);
    }

    function transferERC20(address _tokenAddress, uint _amount) private {
        // CORRECCIÓN: safeTransfer, no safeTransferFrom
        IERC20(_tokenAddress).safeTransfer(msg.sender, _amount);
    }

    /*//////////////////////
            Uniswap helper (mantengo tu función pública también)
    //////////////////////*/

    /**
     * @notice Función para ejecutar swaps de inputs exactos en Uniswap V2 (mantengo para compatibilidad)
     * @dev NO se integra directamente en el flujo de depósitos: ahora los swaps automáticos se realizan en deposit*
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

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut ) public pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            revert SwapModule_InsufficientLiquidity();
        }

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        amountOut = numerator / denominator;
    }

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return FACTORY.getPair(tokenA, tokenB);
    }

    /*//////////////////
            Otras (getters)
    //////////////////*/

    function getBalance() external view returns(uint balance_) {
        balance_ = s_balances[msg.sender][address(0)];
    }

    function getBalanceInUSD() external view returns(uint balance_) {
        balance_ = convertEthInUSD(s_balances[msg.sender][address(0)]);
    }

    function getDeposits() external view returns(uint deposits_) {
        deposits_ = s_deposits[msg.sender][address(0)];
    }

    function getWithdrawals() external view returns(uint withdrawals_) {
        withdrawals_ = s_withdrawals[msg.sender][address(0)];
    }
}
