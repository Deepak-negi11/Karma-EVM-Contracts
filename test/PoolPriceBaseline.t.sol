// SPDX-License-Identifier: AEL
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { AccumulatorVault } from "../src/AccumulatorVault.sol";
import { Coin } from "../src/Coin.sol";
import { Karma } from "../src/Karma.sol";
import { KarmaAdapterFactory } from "../src/KarmaAdapterFactory.sol";
import { PredictionPool } from "../src/PredictionPool.sol";
import { PredictionPoolFactory } from "../src/PredictionPoolFactory.sol";
import { IOracle } from "../src/interfaces/IOracle.sol";
import { MockBaseToken } from "./mocks/Mocks.sol";

contract FixedOracle is IOracle {
    uint256 private immutable _value;

    constructor(uint256 value_) {
        _value = value_;
    }

    function readValue() external view returns (uint256) {
        return _value;
    }

    function readValueInterval() external view returns (uint256, uint256) {
        return (_value, _value);
    }

    function lastUpdated() external view returns (uint256) {
        return block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "Fixed oracle";
    }
}

contract SettableOracle is IOracle {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }

    function set(uint256 value_) external {
        value = value_;
    }

    function readValue() external view returns (uint256) {
        return value;
    }

    function readValueInterval() external view returns (uint256, uint256) {
        return (value, value);
    }

    function lastUpdated() external view returns (uint256) {
        return block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "Settable oracle";
    }
}

// A pool created while its oracle reads 0 (e.g. a Karma with no submissions)
// must take the first real price as its baseline, not rebalance against a placeholder.
contract PoolPriceBaselineTest is Test {
    uint256 private constant INITIAL_DEPOSIT = 1_000e18;
    uint256 private constant HALF = INITIAL_DEPOSIT / 2;

    MockBaseToken private baseToken;
    PredictionPoolFactory private poolFactory;
    PredictionPool private sourcePool;
    Karma private karma;

    address private trader = makeAddr("trader");

    function setUp() public {
        baseToken = new MockBaseToken();
        poolFactory =
            new PredictionPoolFactory(address(new AccumulatorVault(address(1), address(2))));
        baseToken.mint(address(this), 10 * INITIAL_DEPOSIT);
        baseToken.approve(address(poolFactory), type(uint256).max);

        // Source pool gives this contract a balanced 500/500 position to report with.
        sourcePool = _createPool(address(new FixedOracle(2_500e18)));
        karma = Karma(new KarmaAdapterFactory().createKarma(address(sourcePool), 0, 0, "Karma"));
    }

    function _createPool(address oracle) private returns (PredictionPool) {
        return PredictionPool(
            poolFactory.createPool(
                "Pool",
                address(baseToken),
                oracle,
                "Bull",
                "BULL",
                "Bear",
                "BEAR",
                500,
                500,
                500,
                300,
                INITIAL_DEPOSIT
            )
        );
    }

    function test_nonZeroOracleSetsPreviousPrice() public view {
        assertEq(sourcePool.previousPrice(), 2_500e18);
    }

    function test_zeroOracleLeavesNoBaseline() public {
        assertEq(karma.readValue(), 0);
        PredictionPool pool = _createPool(address(karma));
        assertEq(pool.previousPrice(), 0);
    }

    function test_firstOraclePriceBecomesBaselineWithoutMovingReserves() public {
        PredictionPool pool = _createPool(address(karma));

        karma.submitPrice(2_000e18);
        pool.rebalance();

        assertEq(baseToken.balanceOf(address(pool.bullCoin())), HALF);
        assertEq(baseToken.balanceOf(address(pool.bearCoin())), HALF);
        assertEq(pool.previousPrice(), 2_000e18);
    }

    function test_bearBoughtBeforeFirstPriceKeepsValue() public {
        PredictionPool pool = _createPool(address(karma));
        Coin bear = pool.bearCoin();

        baseToken.mint(trader, 100e18);
        vm.startPrank(trader);
        baseToken.approve(address(bear), 100e18);
        uint256 coins = bear.buy(trader, 100e18);
        vm.stopPrank();

        karma.submitPrice(2_000e18);

        vm.prank(trader);
        uint256 assetOut = bear.sell(coins);
        // Mint fees (mint + creator + dev = 1.3%) leave 98.7e18 coins at par; burn fees leave 97.4169e18.
        assertEq(coins, 98.7e18);
        assertEq(assetOut, 97.4169e18);
    }

    function test_priceMovesAfterBaselineStillRebalance() public {
        PredictionPool pool = _createPool(address(karma));
        address bull = address(pool.bullCoin());

        karma.submitPrice(2_000e18);
        pool.rebalance();
        vm.warp(block.timestamp + 1);
        karma.submitPrice(4_000e18);
        assertEq(karma.readValue(), 4_000e18);
        pool.rebalance();

        // Price doubles: bull target = 1000 * 1000 / (1000 + 250) = 800.
        assertEq(baseToken.balanceOf(bull), 800e18);
        assertEq(pool.previousPrice(), 4_000e18);
    }

    function test_switchToZeroOracleClearsBaseline() public {
        // Switch to Karma before its first submission (the README submits first).
        PredictionPool pool = _createPool(address(new FixedOracle(1e18)));
        assertEq(pool.previousPrice(), 1e18);

        pool.updateOracle(address(karma));
        assertEq(pool.previousPrice(), 0);

        karma.submitPrice(2_000e18);
        pool.rebalance();

        assertEq(baseToken.balanceOf(address(pool.bullCoin())), HALF);
        assertEq(baseToken.balanceOf(address(pool.bearCoin())), HALF);
        assertEq(pool.previousPrice(), 2_000e18);
    }

    function test_switchToPricedOracleUsesItsPrice() public {
        PredictionPool pool = _createPool(address(karma));
        address priced = address(new FixedOracle(3_000e18));

        vm.expectEmit(true, true, false, false, address(pool));
        emit PredictionPool.OracleUpdated(address(karma), priced);
        pool.updateOracle(priced);

        assertEq(pool.previousPrice(), 3_000e18);
    }

    function test_resettingSameOracleWhileZeroKeepsBaseline() public {
        SettableOracle oracle = new SettableOracle(2_000e18);
        PredictionPool pool = _createPool(address(oracle));

        oracle.set(0);
        pool.updateOracle(address(oracle));
        assertEq(pool.previousPrice(), 2_000e18);

        oracle.set(4_000e18);
        pool.rebalance();

        // The pending 2000 -> 4000 move still applies: bull target = 800.
        assertEq(baseToken.balanceOf(address(pool.bullCoin())), 800e18);
    }

    function test_resettingSameOracleWithPriceUsesItsPrice() public {
        SettableOracle oracle = new SettableOracle(2_000e18);
        PredictionPool pool = _createPool(address(oracle));

        oracle.set(3_000e18);
        pool.updateOracle(address(oracle));

        assertEq(pool.previousPrice(), 3_000e18);
    }
}
