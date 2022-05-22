// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "hardhat/console.sol";

interface ISwapRouter {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @title Bank's Swapper
/// @author Romuald Hog
/// @notice Used to swap the tokens using a DEX router.
/// @notice Used by the bankroll to payout the bet's profit, and to swap the lost bet amount for gas token.
abstract contract Swapper is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Swap router address
    /// @dev Should have the same interface than UniswapV2
    ISwapRouter public swapRouter;

    /// @notice Maps tokens addresses to the swap route path, excluding the token out.
    /// @dev If, for example, a direct pair does not exist.
    mapping(address => address[]) public swapRoutePaths;

    /// @notice Gas token / USD price feed.
    AggregatorV3Interface public gasToken_USD_priceFeed;

    /// @notice Maps tokens addresses to the USD price feed.
    mapping(address => AggregatorV3Interface) public tokensPriceFeed;

    /// @notice Emitted after the swap router is set.
    /// @param router Address of the router.
    /// @dev The router should have the same interface than Uniswap v2.
    event SetSwapRouter(address router);

    /// @notice Emitted after the token's swap route path is set.
    /// @param token Address of the token.
    /// @param path The tokens addresses from which the swap should be routed.
    event SetTokenSwapRoutePath(address indexed token, address[] path);

    /// @notice Emitted after the Gas token/USD price feed is set.
    /// @param gasToken_USD_priceFeed Address of the Chainlink Data Feed.
    event SetGasToken_USD_priceFeed(address gasToken_USD_priceFeed);

    /// @notice Emitted after the token's price feed is set.
    /// @param tokenPriceFeed Address of the token's Chainlink Data Feed.
    event SetTokenPriceFeed(address tokenPriceFeed);

    /// @notice Emitted after the gas token swap.
    /// @param token Address of the token to buy.
    /// @param gasTokenAmountIn Amount of gas token spent.
    /// @param betTokenAmountOut Amount of token received.
    event GasTokenSwap(
        address indexed token,
        uint256 gasTokenAmountIn,
        uint256 betTokenAmountOut
    );

    /// @notice Emitted after the bet token swap.
    /// @param token Address of the token to sell.
    /// @param betTokenAmountIn Amount of gas token spent.
    /// @param gasTokenAmountOut Amount of token received.
    event BetTokenSwap(
        address indexed token,
        uint256 betTokenAmountIn,
        uint256 gasTokenAmountOut
    );

    /// @notice Reverting error when setting wrong token's swap route path.
    error WrongTokenSwapRoutePath();
    /// @notice Reverting error when setting wrong token's price feed.
    error WrongTokenPriceFeeds();

    /// @notice Initialize the contract's admin role to the deployer, and state variables.
    /// @param _swapRouter The DEX router address with the UniswapV2Router01 interface.
    /// @param _gasToken_USD_priceFeed The Gas Token / USD Chainlink price feed address.
    constructor(
        ISwapRouter _swapRouter,
        AggregatorV3Interface _gasToken_USD_priceFeed
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);

        swapRouter = _swapRouter;
        gasToken_USD_priceFeed = _gasToken_USD_priceFeed;
    }

    /// @notice Derives denominated price pairs in other currencies.
    /// @param price The base amount to scale.
    /// @param priceDecimals The base decimals.
    /// @param decimals The desired decimals.
    /// @return price The scaled price.
    function _scalePrice(
        int256 price,
        uint8 priceDecimals,
        uint8 decimals
    ) private pure returns (int256) {
        if (priceDecimals < decimals) {
            return price * int256(10**uint256(decimals - priceDecimals));
        } else if (priceDecimals > decimals) {
            return price / int256(10**uint256(priceDecimals - decimals));
        }
        return price;
    }

    /// @notice Toggles the token's approval on the router.
    /// @param tokenAddress The token address.
    function _toggleTokenSwapRouterApproval(address tokenAddress) internal {
        IERC20 token = IERC20(tokenAddress);
        uint256 allowance = 0;
        if (token.allowance(address(this), address(swapRouter)) == 0) {
            allowance = type(uint256).max;
        }
        token.safeApprove(address(swapRouter), allowance);
    }

    /// @notice Swaps an exact amount of gas token for as many output tokens as possible, along the route determined by the path.
    /// @notice This is called by the bankroll to payout the bet's profit.
    /// @param user The user to transfer funds to.
    /// @param token The output token of the swap.
    /// @param tokenAmount The token amount out expected.
    /// @return gasTokenAmountIn The amount of gas token paid for the swap.
    /// @return betTokenAmountOut The amount of bet token received after the swap.
    function _swapExactGasTokenForTokens(
        address user,
        address token,
        uint256 tokenAmount
    ) internal returns (uint256, uint256) {
        uint256 gasTokenAmount = uint256(
            (_scalePrice(
                int256(tokenAmount),
                IERC20Metadata(token).decimals(),
                18
            ) * getGasTokenQuotePriceFromToken(token)) / 10**18
        );

        address[] memory swapRoutePath = swapRoutePaths[token];
        uint256 swapRoutePathLength = swapRoutePath.length;
        address[] memory path = new address[](swapRoutePathLength + 2);
        path[0] = swapRouter.WETH();
        if (swapRoutePathLength != 0) {
            for (uint8 i = 0; i < swapRoutePathLength; i++) {
                path[i + 1] = swapRoutePath[i];
            }
        }
        path[path.length - 1] = token;

        uint256[] memory amounts = swapRouter.swapExactETHForTokens{
            value: gasTokenAmount
        }(0, path, user, block.timestamp);
        emit GasTokenSwap(token, amounts[0], amounts[path.length - 1]);

        return (amounts[0], amounts[path.length - 1]);
    }

    /// @notice Swaps an exact amount of tokens for as much gas token as possible, along the route determined by the path.
    /// @notice This is called by the bankroll to swap the lost bet amount for gas token.
    /// @param token The output token of the swap.
    /// @param tokenAmount The token amount input.
    /// @return betTokenAmountIn The amount of bet token paid for the swap.
    /// @return gasTokenAmountOut The amount of gas token received after the swap.
    function _swapExactTokensForGasToken(address token, uint256 tokenAmount)
        internal
        returns (uint256, uint256)
    {
        address[] memory swapRoutePath = swapRoutePaths[token];
        uint256 swapRoutePathLength = swapRoutePath.length;
        address[] memory path = new address[](swapRoutePathLength + 2);
        path[0] = token;
        if (swapRoutePathLength != 0) {
            for (uint8 i = 0; i < swapRoutePathLength; i++) {
                path[i + 1] = swapRoutePath[i];
            }
        }
        path[path.length - 1] = swapRouter.WETH();

        uint256[] memory amounts = swapRouter.swapExactTokensForETH(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
        emit BetTokenSwap(token, amounts[0], amounts[path.length - 1]);

        return (amounts[0], amounts[path.length - 1]);
    }

    /// @notice Changes the swap router.
    /// @param _swapRouter Address of the DEX router.
    function setSwapRouter(ISwapRouter _swapRouter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        swapRouter = _swapRouter;
        emit SetSwapRouter(address(_swapRouter));
    }

    /// @notice Changes the token's swap route path.
    /// @param token Address of the token.
    /// @param path Intermediate pairs to trade through.
    function setTokenSwapRoutePath(address token, address[] calldata path)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (path[0] == swapRouter.WETH() || path[path.length - 1] == token) {
            revert WrongTokenSwapRoutePath();
        }
        swapRoutePaths[token] = path;
        emit SetTokenSwapRoutePath(token, path);
    }

    /// @notice Changes the gas token price feed.
    /// @param _gasToken_USD_priceFeed Address of Chainlink's Gas Token / USD price feed.
    function setGasToken_USD_priceFeed(
        AggregatorV3Interface _gasToken_USD_priceFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gasToken_USD_priceFeed = _gasToken_USD_priceFeed;
        emit SetGasToken_USD_priceFeed(address(_gasToken_USD_priceFeed));
    }

    /// @notice Changes the token's price feed.
    /// @param token Address of the token.
    /// @param tokenPriceFeed Address of Chainlink's Token / USD price feed.
    function setTokenPriceFeed(
        address token,
        AggregatorV3Interface tokenPriceFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokensPriceFeed[token] = tokenPriceFeed;
        emit SetTokenPriceFeed(address(tokenPriceFeed));
    }

    /// @notice Get the token swap route path.
    /// @param token Address of the token.
    /// @return Length of the route path.
    function getTokenSwapRoutePathLength(address token)
        external
        view
        returns (uint256)
    {
        return swapRoutePaths[token].length;
    }

    /// @notice Derives the bet token price in gas token price.
    /// @param betToken Address of the token.
    /// @return Gas Token / Bet token price.
    function getBetTokenPriceQuoteFromGasToken(address betToken)
        public
        view
        returns (int256)
    {
        uint8 quoteTokenDecimals = IERC20Metadata(betToken).decimals();

        (, int256 basePrice, , , ) = gasToken_USD_priceFeed.latestRoundData();
        basePrice = _scalePrice(
            basePrice,
            gasToken_USD_priceFeed.decimals(),
            quoteTokenDecimals
        );

        AggregatorV3Interface tokenPriceFeed = tokensPriceFeed[betToken];
        (, int256 quotePrice, , , ) = tokenPriceFeed.latestRoundData();
        quotePrice = _scalePrice(
            quotePrice,
            tokenPriceFeed.decimals(),
            quoteTokenDecimals
        );
        return (basePrice * int256(10**quoteTokenDecimals)) / quotePrice;
    }

    /// @notice Derives the gas token price in bet token price.
    /// @param betToken Address of the bet token.
    /// @return Bet token / Gas token price.
    function getGasTokenQuotePriceFromToken(address betToken)
        public
        view
        returns (int256)
    {
        uint8 quoteTokenDecimals = 18;

        AggregatorV3Interface tokenPriceFeed = tokensPriceFeed[betToken];
        (, int256 basePrice, , , ) = tokenPriceFeed.latestRoundData();
        basePrice = _scalePrice(
            basePrice,
            tokenPriceFeed.decimals(),
            quoteTokenDecimals
        );

        (, int256 quotePrice, , , ) = gasToken_USD_priceFeed.latestRoundData();
        quotePrice = _scalePrice(
            quotePrice,
            gasToken_USD_priceFeed.decimals(),
            quoteTokenDecimals
        );

        return (basePrice * int256(10**quoteTokenDecimals)) / quotePrice;
    }
}
