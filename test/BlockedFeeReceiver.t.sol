// SPDX-License-Identifier: AEL
pragma solidity ^0.8.23;

import { Test, Vm } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccumulatorVault } from "../src/AccumulatorVault.sol";
import { Coin } from "../src/Coin.sol";
import { PredictionPool } from "../src/PredictionPool.sol";
import { PredictionPoolFactory } from "../src/PredictionPoolFactory.sol";
import { MockOracle } from "./PoolSystem.t.sol";

// Base token whose issuer can block an address from receiving, like the USDC blocklist.
// Some tokens return false instead of reverting, so both ways are covered.
contract BlockableToken is ERC20 {
    error Blocked();

    mapping(address => bool) public blocked;
    bool public returnFalse;

    constructor() ERC20("Blockable", "BLK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (blocked[to]) {
            if (returnFalse) return false;
            revert Blocked();
        }
        return super.transfer(to, value);
    }
}

// A fee receiver that refuses payment must not stop buys and sells.
contract BlockedFeeReceiverTest is Test {
    BlockableToken private token;
    AccumulatorVault private vault;
    PredictionPool private pool;
    Coin private bull;
    address private creator = makeAddr("creator");
    address private trader = makeAddr("trader");
    uint256 private coins;

    function setUp() public {
        token = new BlockableToken();
        vault = new AccumulatorVault(makeAddr("dev"), makeAddr("receiver"));
        PredictionPoolFactory factory = new PredictionPoolFactory(address(vault));

        token.mint(creator, 1_000e18);
        vm.startPrank(creator);
        token.approve(address(factory), type(uint256).max);
        pool = PredictionPool(
            factory.createPool(
                "Karma market",
                address(token),
                address(new MockOracle(1e18)),
                "Bull",
                "BULL",
                "Bear",
                "BEAR",
                500,
                500,
                500,
                300,
                1_000e18
            )
        );
        vm.stopPrank();
        bull = pool.bullCoin();

        token.mint(trader, 200e18);
        vm.prank(trader);
        token.approve(address(bull), type(uint256).max);
        vm.prank(trader);
        coins = bull.buy(trader, 100e18);
    }

    function test_sellPaysEveryFeeWhenNothingIsBlocked() public {
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 vaultBefore = token.balanceOf(address(vault));

        _sellHalf();

        assertGt(token.balanceOf(creator), creatorBefore);
        assertGt(token.balanceOf(address(vault)), vaultBefore);
    }

    function test_sellWorksWhenCreatorIsBlocked() public {
        _checkSellWhenBlocked(creator, false);
    }

    function test_sellWorksWhenVaultIsBlocked() public {
        _checkSellWhenBlocked(address(vault), false);
    }

    function test_sellWorksWhenTokenReturnsFalse() public {
        _checkSellWhenBlocked(creator, true);
    }

    function test_buyWorksWhenCreatorIsBlocked() public {
        _checkBuyWhenBlocked(creator);
    }

    function test_buyWorksWhenVaultIsBlocked() public {
        _checkBuyWhenBlocked(address(vault));
    }

    function test_sellWorksWhenBothReceiversAreBlocked() public {
        uint256 snap = vm.snapshotState();
        (uint256 normalOut, uint256 normalReserve, uint256 normalDev, uint256 normalCreator) =
            _sellAndReadFees();
        vm.revertToState(snap);

        token.setBlocked(creator, true);
        token.setBlocked(address(vault), true);
        (uint256 out, uint256 reserve, uint256 dev, uint256 creatorFee) = _sellAndReadFees();

        assertEq(out, normalOut, "seller gets the same amount");
        assertEq(reserve, normalReserve + normalDev + normalCreator, "both fees stay in reserve");
        assertEq(dev, 0);
        assertEq(creatorFee, 0);
    }

    // The seller gets the same amount as when nothing is blocked. The refused fee stays in the
    // coin's reserve and FeeDistribution reports 0 for it.
    function _checkSellWhenBlocked(address receiver, bool returnFalse) private {
        uint256 snap = vm.snapshotState();
        (uint256 normalOut, uint256 normalReserve, uint256 normalDev, uint256 normalCreator) =
            _sellAndReadFees();
        vm.revertToState(snap);

        token.setReturnFalse(returnFalse);
        token.setBlocked(receiver, true);
        uint256 receiverBefore = token.balanceOf(receiver);
        (uint256 out, uint256 reserve, uint256 dev, uint256 creatorFee) = _sellAndReadFees();

        uint256 refused = receiver == creator ? normalCreator : normalDev;
        assertGt(refused, 0);
        assertEq(out, normalOut, "seller gets the same amount");
        assertEq(reserve, normalReserve + refused, "refused fee stays in reserve");
        assertEq(token.balanceOf(receiver), receiverBefore, "blocked receiver gets nothing");
        assertEq(dev, receiver == creator ? normalDev : 0);
        assertEq(creatorFee, receiver == creator ? 0 : normalCreator);
    }

    function _checkBuyWhenBlocked(address receiver) private {
        uint256 snap = vm.snapshotState();
        (uint256 normalCoins, uint256 normalReserve, uint256 normalDev, uint256 normalCreator) =
            _buyAndReadFees();
        vm.revertToState(snap);

        token.setBlocked(receiver, true);
        (uint256 minted, uint256 reserve, uint256 dev, uint256 creatorFee) = _buyAndReadFees();

        uint256 refused = receiver == creator ? normalCreator : normalDev;
        assertGt(refused, 0);
        assertEq(minted, normalCoins, "buyer gets the same coins");
        assertEq(reserve, normalReserve + refused, "refused fee stays in reserve");
        assertEq(dev, receiver == creator ? normalDev : 0);
        assertEq(creatorFee, receiver == creator ? 0 : normalCreator);
    }

    function _sellHalf() private returns (uint256) {
        vm.prank(trader);
        return bull.sell(coins / 2);
    }

    function _sellAndReadFees()
        private
        returns (uint256 out, uint256 reserve, uint256 dev, uint256 creatorFee)
    {
        vm.recordLogs();
        out = _sellHalf();
        reserve = token.balanceOf(address(bull));
        (dev, creatorFee) = _paidFees();
    }

    function _buyAndReadFees()
        private
        returns (uint256 minted, uint256 reserve, uint256 dev, uint256 creatorFee)
    {
        vm.recordLogs();
        vm.prank(trader);
        minted = bull.buy(trader, 100e18);
        reserve = token.balanceOf(address(bull));
        (dev, creatorFee) = _paidFees();
    }

    function _paidFees() private view returns (uint256 dev, uint256 creatorFee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != Coin.FeeDistribution.selector) continue;
            // Data: blockNumber, totalFeeAmount, vaultFeeAmount, devFeeAmount,
            // creatorFeeAmount, accumulatorVault, timestamp.
            (,,, dev, creatorFee,,) = abi.decode(
                logs[i].data, (uint256, uint256, uint256, uint256, uint256, address, uint256)
            );
        }
    }
}
