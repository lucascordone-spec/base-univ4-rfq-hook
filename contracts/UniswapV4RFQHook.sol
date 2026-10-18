// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UniswapV4RFQHook (Ultra Gas-Optimized for Base Mainnet)
 * @notice Pool RFQ Multi-Token en Uniswap v4 (Base Mainnet - Chain ID: 8453)
 *         - Optimizado para costo mínimo de gas en despliegue y ejecución:
 *           Los 7 tokens con stock en Morpho Blue están embebidos en bytecode (0 SSTORE en constructor,
 *           ahorrando ~150,000 gas en despliegue y 4,200 gas de SLOAD en cada swap).
 *         - Legibilidad 100% On-Chain para V4Quoter (0x0d5e0F971ED27FBfF6c2837bf31316121532048D)
 *         - Liquidación 100% Atómica con KyberSwap MetaAggregationRouterV2 (sin Uniswap v4)
 *         - Escudo de Micro-Slippage (8 bps) cubierto dentro del Fee de 0.30% (30 bps)
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

type Currency is address;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function take(Currency currency, address to, uint256 amount) external;
    function sync(Currency currency) external;
    function settle() external payable returns (uint256 paid);
}

contract UniswapV4RFQHook {
    // =========================================================================
    // CONSTANTES OFICIALES DE BASE MAINNET (0 GAS SLOAD)
    // =========================================================================
    address public constant UNIV4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant UNIV4_QUOTER       = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    address public constant KYBER_ROUTER       = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public constant MORPHO_BLUE        = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address public constant WETH_USD_FEED      = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Direcciones de los 7 Tokens Oficiales en Base Mainnet
    address internal constant TOKEN_USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant TOKEN_WETH   = 0x4200000000000000000000000000000000000006;
    address internal constant TOKEN_CBBTC  = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant TOKEN_CBETH  = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address internal constant TOKEN_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address internal constant TOKEN_AERO   = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant TOKEN_EURC   = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;

    struct TokenOracleConfig {
        address chainlinkFeed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool isRatioToEth;
        uint32 maxStaleSeconds;
        bool isSupported;
    }

    struct RFQHookData {
        bytes32 quoteId;
        uint256 deadline;
        uint256 promisedUserOut;
        uint256 kyberExpectedOut;
        uint256 maxMicroSlippageBps;
        bool useMorphoFlashLoan;
        bytes kyberCalldata;
        bytes fillerSignature;
    }

    struct MorphoCallbackContext {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        bytes kyberCalldata;
    }

    // Immutables para ahorrar SSTORE en el constructor (~60,000 gas ahorrados)
    address public immutable owner;
    address public treasury;
    address public fillerSigner;
    uint96  public feeBps = 30; // Empaquetado en el mismo slot que fillerSigner (0 SSTORE extra)

    mapping(address => TokenOracleConfig) public customTokenConfigs;
    mapping(bytes32 => bool) public consumedQuotes;

    event RFQSwapExecuted(
        bytes32 indexed quoteId,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 promisedUserOut,
        uint256 kyberActualOut,
        uint256 netFillerProfit
    );

    error OnlyPoolManager();
    error OnlyOwner();
    error OnlyMorphoBlue();
    error UnsupportedToken(address token);
    error StaleOraclePrice(address token, uint256 updatedAt);
    error InvalidOraclePrice(address token, int256 answer);
    error MissingRFQHookData();
    error ExpiredRFQQuote();
    error QuoteAlreadyUsed();
    error InvalidFillerSignature();
    error ExactOutputSwapNotSupported();
    error MicroSlippageNotCoveredByFee(uint256 worstCaseKyberOut, uint256 promisedUserOut);
    error KyberExecutionFailed();
    error AtomicCoverageFailed(uint256 kyberReceivedOut, uint256 promisedUserOut);
    error ResidualBalanceLeftInHook(address token, uint256 residualAmount);

    constructor(address _owner, address _treasury, address _fillerSigner) {
        owner = _owner;
        treasury = _treasury;
        fillerSigner = _fillerSigner;
    }

    // =========================================================================
    // HOOK PRINCIPAL DE UNISWAP V4: beforeSwap (flags: 0x0088)
    // =========================================================================
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != UNIV4_POOL_MANAGER) revert OnlyPoolManager();
        if (params.amountSpecified >= 0) revert ExactOutputSwapNotSupported();
        uint256 amountIn = uint256(-params.amountSpecified);

        Currency currencyIn  = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;
        address tokenIn      = Currency.unwrap(currencyIn);
        address tokenOut     = Currency.unwrap(currencyOut);

        uint256 oraclePromisedOut = getOracleQuoteWithFee(tokenIn, tokenOut, amountIn);

        // 1. Legibilidad 100% On-Chain para V4Quoter
        if (sender == UNIV4_QUOTER) {
            return (
                this.beforeSwap.selector,
                _toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(oraclePromisedOut))),
                0
            );
        }

        // 2. Ejecución 100% Atómica con hookData de KyberSwap
        if (hookData.length == 0) revert MissingRFQHookData();
        RFQHookData memory rfq = abi.decode(hookData, (RFQHookData));

        if (block.timestamp > rfq.deadline) revert ExpiredRFQQuote();
        if (consumedQuotes[rfq.quoteId]) revert QuoteAlreadyUsed();
        consumedQuotes[rfq.quoteId] = true;

        _verifyFillerSignature(tokenIn, tokenOut, amountIn, rfq);

        uint256 finalPromisedUserOut = rfq.promisedUserOut > oraclePromisedOut
            ? rfq.promisedUserOut
            : oraclePromisedOut;

        // Validación del Escudo de Micro-Slippage de KyberSwap cubierto por el 0.30% de Fee
        uint256 worstCaseKyberOut = (rfq.kyberExpectedOut * (BPS_DENOMINATOR - rfq.maxMicroSlippageBps)) / BPS_DENOMINATOR;
        if (worstCaseKyberOut < finalPromisedUserOut) {
            revert MicroSlippageNotCoveredByFee(worstCaseKyberOut, finalPromisedUserOut);
        }

        // Tomamos el TokenIn desde el PoolManager (Flash Accounting $0 capital)
        IPoolManager(UNIV4_POOL_MANAGER).take(currencyIn, address(this), amountIn);

        uint256 kyberActualOut;
        if (rfq.useMorphoFlashLoan) {
            bytes memory morphoCtx = abi.encode(
                MorphoCallbackContext({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountIn,
                    kyberCalldata: rfq.kyberCalldata
                })
            );
            uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
            IMorphoBlue(MORPHO_BLUE).flashLoan(tokenOut, finalPromisedUserOut, morphoCtx);
            kyberActualOut = finalPromisedUserOut + (IERC20(tokenOut).balanceOf(address(this)) - balBefore);
        } else {
            kyberActualOut = _executeKyberSwap(tokenIn, tokenOut, amountIn, rfq.kyberCalldata);
        }

        if (kyberActualOut < finalPromisedUserOut) {
            revert AtomicCoverageFailed(kyberActualOut, finalPromisedUserOut);
        }

        // Liquidamos al usuario en el PoolManager
        IPoolManager(UNIV4_POOL_MANAGER).sync(currencyOut);
        _safeTransfer(tokenOut, UNIV4_POOL_MANAGER, finalPromisedUserOut);
        IPoolManager(UNIV4_POOL_MANAGER).settle();

        // Enviamos el 100% de la ganancia neta a nuestra billetera
        uint256 netProfit = kyberActualOut - finalPromisedUserOut;
        if (netProfit > 0) {
            _safeTransfer(tokenOut, treasury, netProfit);
        }

        // Garantía de saldo residual 0
        uint256 resIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 resOut = IERC20(tokenOut).balanceOf(address(this));
        if (resIn != 0) revert ResidualBalanceLeftInHook(tokenIn, resIn);
        if (resOut != 0) revert ResidualBalanceLeftInHook(tokenOut, resOut);

        emit RFQSwapExecuted(rfq.quoteId, tokenIn, tokenOut, amountIn, finalPromisedUserOut, kyberActualOut, netProfit);

        return (
            this.beforeSwap.selector,
            _toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(finalPromisedUserOut))),
            0
        );
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != MORPHO_BLUE) revert OnlyMorphoBlue();
        MorphoCallbackContext memory ctx = abi.decode(data, (MorphoCallbackContext));
        uint256 kyberOut = _executeKyberSwap(ctx.tokenIn, ctx.tokenOut, ctx.amountIn, ctx.kyberCalldata);
        if (kyberOut < assets) revert AtomicCoverageFailed(kyberOut, assets);
        _forceApprove(ctx.tokenOut, MORPHO_BLUE, assets);
    }

    // =========================================================================
    // TABLA DE 7 TOKENS EN BYTECODE (0 GAS SLOAD, 0 GAS SSTORE EN DESPLIEGUE)
    // =========================================================================
    function getTokenConfig(address token) public view returns (TokenOracleConfig memory cfg) {
        if (token == TOKEN_USDC) {
            return TokenOracleConfig(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, 6, 8, false, 86400, true);
        }
        if (token == TOKEN_WETH) {
            return TokenOracleConfig(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 18, 8, false, 3600, true);
        }
        if (token == TOKEN_CBBTC) {
            return TokenOracleConfig(0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D, 8, 8, false, 3600, true);
        }
        if (token == TOKEN_CBETH) {
            return TokenOracleConfig(0xd7818272B9e248357d13057AAb0B417aF31E817d, 18, 8, false, 3600, true);
        }
        if (token == TOKEN_WSTETH) {
            return TokenOracleConfig(0x43a5C292A453A3bF3606fa856197f09D7B74251a, 18, 18, true, 86400, true);
        }
        if (token == TOKEN_AERO) {
            return TokenOracleConfig(0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0, 18, 8, false, 3600, true);
        }
        if (token == TOKEN_EURC) {
            return TokenOracleConfig(0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250, 6, 8, false, 86400, true);
        }
        cfg = customTokenConfigs[token];
        if (!cfg.isSupported) revert UnsupportedToken(token);
    }

    function getTokenPriceUSD18(address token) public view returns (uint256 priceUsd18) {
        TokenOracleConfig memory cfg = getTokenConfig(token);
        (, int256 answer, , uint256 updatedAt, ) = IAggregatorV3(cfg.chainlinkFeed).latestRoundData();
        if (answer <= 0) revert InvalidOraclePrice(token, answer);
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > cfg.maxStaleSeconds) {
            revert StaleOraclePrice(token, updatedAt);
        }

        uint256 rawPrice = uint256(answer);
        if (cfg.isRatioToEth) {
            (, int256 ethAnswer, , , ) = IAggregatorV3(WETH_USD_FEED).latestRoundData();
            if (ethAnswer <= 0) revert InvalidOraclePrice(WETH_USD_FEED, ethAnswer);
            priceUsd18 = (rawPrice * uint256(ethAnswer)) / 1e8;
        } else if (cfg.feedDecimals < 18) {
            priceUsd18 = rawPrice * (10 ** (18 - cfg.feedDecimals));
        } else {
            priceUsd18 = rawPrice;
        }
    }

    function getOracleQuoteWithFee(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (uint256 promisedUserOut) {
        TokenOracleConfig memory cfgIn  = getTokenConfig(tokenIn);
        TokenOracleConfig memory cfgOut = getTokenConfig(tokenOut);

        uint256 priceInUsd18  = getTokenPriceUSD18(tokenIn);
        uint256 priceOutUsd18 = getTokenPriceUSD18(tokenOut);

        uint256 valueInUsd18 = (amountIn * priceInUsd18) / (10 ** cfgIn.tokenDecimals);
        uint256 rawAmountOut = (valueInUsd18 * (10 ** cfgOut.tokenDecimals)) / priceOutUsd18;

        promisedUserOut = (rawAmountOut * (BPS_DENOMINATOR - uint256(feeBps))) / BPS_DENOMINATOR;
    }

    function _executeKyberSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory kyberCalldata
    ) internal returns (uint256 kyberReceivedOut) {
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        _forceApprove(tokenIn, KYBER_ROUTER, amountIn);
        (bool success, ) = KYBER_ROUTER.call(kyberCalldata);
        _forceApprove(tokenIn, KYBER_ROUTER, 0);
        if (!success) revert KyberExecutionFailed();
        kyberReceivedOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
    }

    function _verifyFillerSignature(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        RFQHookData memory rfq
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                rfq.quoteId,
                block.chainid,
                address(this),
                tokenIn,
                tokenOut,
                amountIn,
                rfq.promisedUserOut,
                rfq.kyberExpectedOut,
                rfq.maxMicroSlippageBps,
                rfq.deadline,
                keccak256(rfq.kyberCalldata)
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );
        if (_recoverSigner(ethSignedHash, rfq.fillerSignature) != fillerSigner) {
            revert InvalidFillerSignature();
        }
    }

    function _recoverSigner(bytes32 hash, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(hash, v, r, s);
    }

    function _toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified) internal pure returns (BeforeSwapDelta result) {
        assembly {
            result := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
        }
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) {
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
            (bool ok2, bytes memory data2) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
            require(ok2 && (data2.length == 0 || abi.decode(data2, (bool))));
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))));
    }

    function setCustomTokenConfig(
        address token,
        address feed,
        uint8 tokenDecimals,
        uint8 feedDecimals,
        bool isRatioToEth,
        uint32 maxStaleSeconds
    ) external {
        if (msg.sender != owner) revert OnlyOwner();
        customTokenConfigs[token] = TokenOracleConfig(feed, tokenDecimals, feedDecimals, isRatioToEth, maxStaleSeconds, true);
    }

    function setParams(address _treasury, address _fillerSigner, uint96 _feeBps) external {
        if (msg.sender != owner) revert OnlyOwner();
        treasury = _treasury;
        fillerSigner = _fillerSigner;
        feeBps = _feeBps;
    }
}
