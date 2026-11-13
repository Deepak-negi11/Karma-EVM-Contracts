// SPDX-License-Identifier: AEL
pragma solidity ^0.8.23;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPoolRebalance {
    function rebalance() external;
}

struct CoinConfig {
    string name;
    string symbol;
    address asset;
    address vaultCreator;
    address predictionPool;
    address accumulatorVault;
    uint256 mintFee;
    uint256 burnFee;
    uint256 creatorFee;
    uint256 devFee;
}

contract Coin is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DENOMINATOR = 100_000;

    IERC20 public immutable asset;
    address public immutable vaultCreator;
    address public immutable predictionPool;
    address public immutable accumulatorVault;
    uint8 public immutable assetDecimals;
    uint256 public immutable mintFee;
    uint256 public immutable burnFee;
    uint256 public immutable creatorFee;
    uint256 public immutable devFee;

    address public otherCoin;
    uint256 public cumulativeFees;
    uint256 public cumulativeVolume;
    uint256 public tradeCount;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidFeeConfiguration();
    error OnlyPredictionPool();
    error OtherCoinAlreadySet();
    error MissingOtherCoin();
    error UnsupportedDecimals();
    error SupplyWouldBecomeZero();
    error InsufficientReserve();

    event Mint(
        address indexed from,
        address indexed to,
        uint256 amountAsset,
        uint256 amountCoin,
        uint256 price,
        uint256 totalSupplyAfter,
        uint256 reserveAfter,
        uint256 feePaid
    );
    event Burn(
        address indexed from,
        uint256 amountAsset,
        uint256 amountCoin,
        uint256 price,
        uint256 totalSupplyAfter,
        uint256 reserveAfter,
        uint256 feePaid
    );
    event FeeDistribution(
        address indexed user,
        string indexed transactionType,
        uint256 blockNumber,
        uint256 totalFeeAmount,
        uint256 vaultFeeAmount,
        uint256 devFeeAmount,
        uint256 creatorFeeAmount,
        address accumulatorVault,
        address indexed creator,
        uint256 timestamp
    );
    event CoinTransfer(
        address indexed from, address indexed to, uint256 amountSent, uint256 amountReceived
    );

    constructor(CoinConfig memory config) ERC20(config.name, config.symbol) {
        if (
            config.asset == address(0) || config.vaultCreator == address(0)
                || config.predictionPool == address(0) || config.accumulatorVault == address(0)
        ) revert ZeroAddress();
        if (
            config.mintFee + config.creatorFee + config.devFee > DENOMINATOR
                || config.burnFee + config.creatorFee + config.devFee > DENOMINATOR
        ) revert InvalidFeeConfiguration();

        uint8 decimals_ = IERC20Metadata(config.asset).decimals();
        if (decimals_ > 18) revert UnsupportedDecimals();

        asset = IERC20(config.asset);
        vaultCreator = config.vaultCreator;
        predictionPool = config.predictionPool;
        accumulatorVault = config.accumulatorVault;
        assetDecimals = decimals_;
        mintFee = config.mintFee;
        burnFee = config.burnFee;
        creatorFee = config.creatorFee;
        devFee = config.devFee;
    }

    modifier onlyPredictionPool() {
        if (msg.sender != predictionPool) revert OnlyPredictionPool();
        _;
    }

    function owner() external view returns (address) {
        return predictionPool;
    }

    function setOtherCoin(address otherCoin_) external onlyPredictionPool {
        if (otherCoin != address(0)) revert OtherCoinAlreadySet();
        if (otherCoin_ == address(0) || otherCoin_ == address(this)) revert ZeroAddress();
        otherCoin = otherCoin_;
    }

    function mintInitialSupply(uint256 amount) external onlyPredictionPool {
        if (amount == 0) return;
        _mint(vaultCreator, amount);
    }

    function priceBuy() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return DENOMINATOR;
        return Math.mulDiv(
            asset.balanceOf(address(this)), DENOMINATOR * _assetScale(), supply, Math.Rounding.Ceil
        );
    }

    function priceSell() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return DENOMINATOR;
        return Math.mulDiv(asset.balanceOf(address(this)), DENOMINATOR * _assetScale(), supply);
    }

    function calculateFees(uint256 amount, uint256 vaultFee, uint256 _devFee, uint256 _creatorFee)
        external
        pure
        returns (uint256 vaultAmount, uint256 devFeeAmount, uint256 creatorAmount)
    {
        vaultAmount = Math.mulDiv(amount, vaultFee, DENOMINATOR, Math.Rounding.Ceil);
        devFeeAmount = Math.mulDiv(amount, _devFee, DENOMINATOR, Math.Rounding.Ceil);
        creatorAmount = Math.mulDiv(amount, _creatorFee, DENOMINATOR, Math.Rounding.Ceil);
    }

    function buy(address receiver, uint256 amountAsset)
        external
        nonReentrant
        returns (uint256 amountCoin)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (amountAsset == 0) revert ZeroAmount();
        IPoolRebalance(predictionPool).rebalance();

        uint256 price = priceBuy();
        (uint256 vaultAmount, uint256 devAmount, uint256 creatorAmount) = _fees(amountAsset, mintFee);
        uint256 totalFees = vaultAmount + devAmount + creatorAmount;
        if (totalFees >= amountAsset) revert InvalidFeeConfiguration();
        uint256 amountAfterFees = amountAsset - totalFees;
        amountCoin = Math.mulDiv(
            amountAfterFees, DENOMINATOR * _assetScale(), price, Math.Rounding.Ceil
        );
        if (amountCoin == 0) revert ZeroAmount();
        if (otherCoin == address(0)) revert MissingOtherCoin();

        asset.safeTransferFrom(msg.sender, address(this), amountAsset);
        (devAmount, creatorAmount) = _sendFees(vaultAmount, devAmount, creatorAmount);
        _mint(receiver, amountCoin);

        cumulativeVolume += amountAsset;
        cumulativeFees += totalFees;
        tradeCount++;
        emit Mint(
            msg.sender,
            receiver,
            amountAsset,
            amountCoin,
            price,
            totalSupply(),
            asset.balanceOf(address(this)),
            totalFees
        );
        emit FeeDistribution(
            msg.sender,
            "buy",
            block.number,
            totalFees,
            vaultAmount,
            devAmount,
            creatorAmount,
            accumulatorVault,
            vaultCreator,
            block.timestamp
        );
    }

    function sell(uint256 amountCoin) external nonReentrant returns (uint256 amountAsset) {
        if (amountCoin == 0) revert ZeroAmount();
        if (amountCoin >= totalSupply()) revert SupplyWouldBecomeZero();
        IPoolRebalance(predictionPool).rebalance();

        uint256 price = priceSell();
        uint256 amountBeforeFeesWad = Math.mulDiv(amountCoin, price, DENOMINATOR);
        uint256 scale = _assetScale();
        uint256 amountBeforeFees = amountBeforeFeesWad / scale;
        if (amountBeforeFees == 0) revert ZeroAmount();

        (uint256 vaultAmount, uint256 devAmount, uint256 creatorAmount) =
            _fees(amountBeforeFees, burnFee);
        uint256 totalFees = vaultAmount + devAmount + creatorAmount;
        if (totalFees >= amountBeforeFees) revert InvalidFeeConfiguration();
        amountAsset = amountBeforeFees - totalFees;
        if (otherCoin == address(0)) revert MissingOtherCoin();
        if (amountBeforeFees > asset.balanceOf(address(this))) revert InsufficientReserve();

        _burn(msg.sender, amountCoin);
        (devAmount, creatorAmount) = _sendFees(vaultAmount, devAmount, creatorAmount);
        asset.safeTransfer(msg.sender, amountAsset);

        cumulativeVolume += amountBeforeFees;
        cumulativeFees += totalFees;
        tradeCount++;
        emit Burn(
            msg.sender,
            amountAsset,
            amountCoin,
            price,
            totalSupply(),
            asset.balanceOf(address(this)),
            totalFees
        );
        emit FeeDistribution(
            msg.sender,
            "sell",
            block.number,
            totalFees,
            vaultAmount,
            devAmount,
            creatorAmount,
            accumulatorVault,
            vaultCreator,
            block.timestamp
        );
    }

    function transferReserveToOther(uint256 amount) external onlyPredictionPool {
        if (otherCoin == address(0)) revert MissingOtherCoin();
        asset.safeTransfer(otherCoin, amount);
    }

    function _fees(uint256 amount, uint256 sideFee)
        internal
        view
        returns (uint256 vaultAmount, uint256 devAmount, uint256 creatorAmount)
    {
        vaultAmount = Math.mulDiv(amount, sideFee, DENOMINATOR, Math.Rounding.Ceil);
        devAmount = Math.mulDiv(amount, devFee, DENOMINATOR, Math.Rounding.Ceil);
        creatorAmount = Math.mulDiv(amount, creatorFee, DENOMINATOR, Math.Rounding.Ceil);
    }

    // A refused dev or creator fee (for example a blocklisted receiver) must not block buys and
    // sells. That fee stays in this coin's reserve and the returned amount for it is 0.
    function _sendFees(uint256 vaultAmount, uint256 devAmount, uint256 creatorAmount)
        internal
        returns (uint256 devPaid, uint256 creatorPaid)
    {
        if (vaultAmount > 0) asset.safeTransfer(otherCoin, vaultAmount);
        devPaid = _tryPayFee(accumulatorVault, devAmount);
        creatorPaid = _tryPayFee(vaultCreator, creatorAmount);
    }

    function _tryPayFee(address receiver, uint256 amount) internal returns (uint256) {
        if (amount == 0 || !asset.trySafeTransfer(receiver, amount)) return 0;
        return amount;
    }

    function _assetScale() internal view returns (uint256) {
        return 10 ** (18 - assetDecimals);
    }
}
