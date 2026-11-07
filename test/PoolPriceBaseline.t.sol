// SPDX-License-Identifier: AEL
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { AccumulatorVault } from "../src/AccumulatorVault.sol";
import { Coin } from "../src/Coin.sol";
import { Karma } from "../src/Karma.sol";
import { KarmaAdapterFactory } from "../src/KarmaAdapterFactory.sol";
import { PredictionPool } from "../src/PredictionPool.sol";
import { PredictionPoolFactory } from "../src/PredictionPoolFactory.sol";
import { MockBaseToken } from "./mocks/Mocks.sol";
import { MockOracle } from "./PoolSystem.t.sol";

// A pool whose oracle reads 0 must take the first real price as its baseline.
contract PoolPriceBaselineTest is Test {
    uint256 private constant INITIAL_DEPOSIT = 1_000e18;
    uint256 private constant MINT_FEE = 500;
    uint256 private constant BURN_FEE = 500;
    uint256 private constant CREATOR_FEE = 500;
    uint256 private constant DEV_FEE = 300;

    address private trader = makeAddr("trader");

    MockBaseToken private baseToken;
    PredictionPoolFactory private poolFactory;
    PredictionPool private sourcePool;
    Karma private karma;

    function setUp() public {
        baseToken = new MockBaseToken();
        poolFactory = new PredictionPoolFactory(
            address(new AccumulatorVault(makeAddr("dev"), makeAddr("receiver")))
        );
        baseToken.mint(address(this), 10 * INITIAL_DEPOSIT);
        baseToken.approve(address(poolFactory), type(uint256).max);

        // The source pool gives this contract a balanced position to submit Karma prices with.
        sourcePool = _createPool(address(new MockOracle(2_500e18)));
        karma = Karma(new KarmaAdapterFactory().createKarma(address(sourcePool), 0, 0, "Karma"));
    }

    function test_nonZeroOracleSetsPreviousPrice() public view {
        assertEq(sourcePool.previousPrice(), 2_500e18);
    }

    function test_zeroOracleLeavesNoBaseline() public {
        assertEq(karma.readValue(), 0);
        PredictionPool pool = _createPool(address(karma));
        assertEq(pool.previousPrice(), 0);
        (,,,, uint256 lastPrice) = pool.getPoolStats();
        assertEq(lastPrice, 0);
    }

    function test_firstOraclePriceBecomesBaselineWithoutMovingReserves() public {
        PredictionPool pool = _createPool(address(karma));

        karma.submitPrice(2_000e18);
        pool.rebalance();

        _assertReserves(pool, INITIAL_DEPOSIT / 2, INITIAL_DEPOSIT / 2);
        assertEq(pool.previousPrice(), 2_000e18);
    }

    function test_adoptingBaselineEmitsNoEvent() public {
        PredictionPool pool = _createPool(address(karma));
        karma.submitPrice(2_000e18);

        vm.recordLogs();
        pool.rebalance();

        assertEq(vm.getRecordedLogs().length, 0);
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

        // Fees are 1.3% each way: 98.7e18 coins at par, then 97.4169e18 back on sell.
        assertEq(coins, 98.7e18);
        vm.prank(trader);
        assertEq(bear.sell(coins), 97.4169e18);
        assertEq(pool.previousPrice(), 2_000e18);
    }

    function test_priceMovesAfterBaselineStillRebalance() public {
        PredictionPool pool = _createPool(address(karma));

        karma.submitPrice(2_000e18);
        pool.rebalance();
        karma.submitPrice(4_000e18);
        assertEq(karma.readValue(), 4_000e18);
        pool.rebalance();

        // Price doubles: bull target = 1000 * 1000 / (1000 + 250) = 800.
        _assertReserves(pool, 800e18, 200e18);
        assertEq(pool.previousPrice(), 4_000e18);
    }

    function test_zeroReadingKeepsBaselineAndReserves() public {
        MockOracle oracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oracle));

        oracle.setValue(0);
        pool.rebalance();

        _assertReserves(pool, INITIAL_DEPOSIT / 2, INITIAL_DEPOSIT / 2);
        assertEq(pool.previousPrice(), 2_000e18);

        // The kept baseline still applies to the next price.
        oracle.setValue(4_000e18);
        pool.rebalance();
        _assertReserves(pool, 800e18, 200e18);
    }

    function test_switchToZeroOracleClearsBaseline() public {
        // Switch to Karma before its first submission (the README submits first).
        PredictionPool pool = _createPool(address(new MockOracle(1e18)));
        assertEq(pool.previousPrice(), 1e18);

        pool.updateOracle(address(karma));
        assertEq(pool.previousPrice(), 0);

        karma.submitPrice(2_000e18);
        pool.rebalance();

        _assertReserves(pool, INITIAL_DEPOSIT / 2, INITIAL_DEPOSIT / 2);
        assertEq(pool.previousPrice(), 2_000e18);
    }

    function test_switchToZeroOracleDropsPendingMove() public {
        MockOracle oldOracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oldOracle));
        oldOracle.setValue(4_000e18);

        MockOracle newOracle = new MockOracle(0);
        pool.updateOracle(address(newOracle));

        // A price unlike the old oracle's, so a copied old price would move reserves.
        newOracle.setValue(3_000e18);
        pool.rebalance();

        _assertReserves(pool, INITIAL_DEPOSIT / 2, INITIAL_DEPOSIT / 2);
        assertEq(pool.previousPrice(), 3_000e18);
    }

    function test_switchToPricedOracleDropsPendingMove() public {
        MockOracle oldOracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oldOracle));
        oldOracle.setValue(4_000e18);

        pool.updateOracle(address(new MockOracle(4_000e18)));
        pool.rebalance();

        _assertReserves(pool, INITIAL_DEPOSIT / 2, INITIAL_DEPOSIT / 2);
        assertEq(pool.previousPrice(), 4_000e18);
    }

    function test_rebalanceBeforeSwitchKeepsPendingMove() public {
        MockOracle oldOracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oldOracle));
        oldOracle.setValue(4_000e18);

        pool.rebalance();
        pool.updateOracle(address(new MockOracle(0)));

        _assertReserves(pool, 800e18, 200e18);
        assertEq(pool.previousPrice(), 0);
    }

    function test_switchToPricedOracleUsesItsPrice() public {
        PredictionPool pool = _createPool(address(karma));
        address priced = address(new MockOracle(3_000e18));

        vm.expectEmit(true, true, false, false, address(pool));
        emit PredictionPool.OracleUpdated(address(karma), priced);
        pool.updateOracle(priced);

        assertEq(pool.previousPrice(), 3_000e18);
    }

    function test_resettingSameOracleWhileZeroKeepsBaseline() public {
        MockOracle oracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oracle));

        oracle.setValue(0);
        pool.updateOracle(address(oracle));
        assertEq(pool.previousPrice(), 2_000e18);

        oracle.setValue(4_000e18);
        pool.rebalance();

        // The pending 2000 -> 4000 move still applies.
        _assertReserves(pool, 800e18, 200e18);
    }

    function test_resettingSameOracleWithPriceUsesItsPrice() public {
        MockOracle oracle = new MockOracle(2_000e18);
        PredictionPool pool = _createPool(address(oracle));

        oracle.setValue(3_000e18);
        pool.updateOracle(address(oracle));

        assertEq(pool.previousPrice(), 3_000e18);
    }

    function _createPool(address oracle) private returns (PredictionPool) {
        return PredictionPool(
            poolFactory.createPool(
                "Karma market",
                address(baseToken),
                oracle,
                "Bull",
                "BULL",
                "Bear",
                "BEAR",
                MINT_FEE,
                BURN_FEE,
                CREATOR_FEE,
                DEV_FEE,
                INITIAL_DEPOSIT
            )
        );
    }

    function _assertReserves(PredictionPool pool, uint256 bullReserve, uint256 bearReserve)
        private
        view
    {
        assertEq(baseToken.balanceOf(address(pool.bullCoin())), bullReserve);
        assertEq(baseToken.balanceOf(address(pool.bearCoin())), bearReserve);
    }
}
