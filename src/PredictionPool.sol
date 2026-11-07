// SPDX-License-Identifier: AEL
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IOracle } from "./interfaces/IOracle.sol";
import { Coin, CoinConfig } from "./Coin.sol";

interface ICoinFactory {
    function createCoin(bytes calldata encodedConfig) external returns (address);
}

struct PredictionPoolConfig {
    string poolName;
    address baseToken;
    address vaultCreator;
    address oracle;
    address accumulatorVault;
    address coinFactory;
    string bullName;
    string bullSymbol;
    string bearName;
    string bearSymbol;
    uint256 mintFee;
    uint256 burnFee;
    uint256 creatorFee;
    uint256 devFee;
    uint256 initialDeposit;
}

contract PredictionPool is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant DENOMINATOR = 100_000;

    string public poolName;
    IERC20 public immutable baseToken;
    Coin public immutable bullCoin;
    Coin public immutable bearCoin;
    address public immutable accumulatorVault;
    address public immutable vaultCreator;
    address public immutable factory;
    uint256 public immutable mintFee;
    uint256 public immutable burnFee;
    uint256 public immutable creatorFee;
    uint256 public immutable devFee;
    uint256 public immutable expectedInitialDeposit;

    IOracle public oracle;
    uint256 public previousPrice;
    bool public initialized;

    error InvalidAddress();
    error InvalidOracle();
    error InvalidFeeConfiguration();
    error OnlyFactory();
    error PoolAlreadyInitialized();
    error InitialDepositMismatch();

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event PoolInitialized(
        address indexed creator,
        uint256 totalDeposit,
        uint256 bullDeposit,
        uint256 bearDeposit,
        uint256 timestamp
    );
    event Rebalanced(
        address indexed caller,
        uint256 indexed blockNumber,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 priceChangePercent,
        uint256 bullReservesBefore,
        uint256 bearReservesBefore,
        uint256 bullReservesAfter,
        uint256 bearReservesAfter,
        uint256 transferAmount,
        bool wasTransferToBull,
        uint256 timestamp
    );

    constructor(address initialOwner, bytes memory encodedConfig) Ownable(initialOwner) {
        PredictionPoolConfig memory config = abi.decode(encodedConfig, (PredictionPoolConfig));
        if (initialOwner != config.vaultCreator) revert InvalidAddress();
        if (
            config.baseToken == address(0) || config.vaultCreator == address(0)
                || config.oracle == address(0) || config.accumulatorVault == address(0)
                || config.coinFactory == address(0)
        ) revert InvalidAddress();
        if (
            config.mintFee + config.creatorFee + config.devFee > DENOMINATOR
                || config.burnFee + config.creatorFee + config.devFee > DENOMINATOR
        ) revert InvalidFeeConfiguration();
        if (IERC20Metadata(config.baseToken).decimals() > 18) revert InvalidAddress();
        _checkOracle(config.oracle);

        poolName = config.poolName;
        baseToken = IERC20(config.baseToken);
        oracle = IOracle(config.oracle);
        accumulatorVault = config.accumulatorVault;
        vaultCreator = config.vaultCreator;
        factory = msg.sender;
        mintFee = config.mintFee;
        burnFee = config.burnFee;
        creatorFee = config.creatorFee;
        devFee = config.devFee;
        expectedInitialDeposit = config.initialDeposit;

        // 0 means no baseline yet: rebalance() adopts the first non-zero price.
        previousPrice = IOracle(config.oracle).readValue();

        bullCoin = Coin(
            ICoinFactory(config.coinFactory).createCoin(
                abi.encode(
                    CoinConfig({
                        name: config.bullName,
                        symbol: config.bullSymbol,
                        asset: config.baseToken,
                        vaultCreator: config.vaultCreator,
                        predictionPool: address(this),
                        accumulatorVault: config.accumulatorVault,
                        mintFee: config.mintFee,
                        burnFee: config.burnFee,
                        creatorFee: config.creatorFee,
                        devFee: config.devFee
                    })
                )
            )
        );
        bearCoin = Coin(
            ICoinFactory(config.coinFactory).createCoin(
                abi.encode(
                    CoinConfig({
                        name: config.bearName,
                        symbol: config.bearSymbol,
                        asset: config.baseToken,
                        vaultCreator: config.vaultCreator,
                        predictionPool: address(this),
                        accumulatorVault: config.accumulatorVault,
                        mintFee: config.mintFee,
                        burnFee: config.burnFee,
                        creatorFee: config.creatorFee,
                        devFee: config.devFee
                    })
                )
            )
        );
        bullCoin.setOtherCoin(address(bearCoin));
        bearCoin.setOtherCoin(address(bullCoin));
    }

    function initialize(uint256 initialDeposit_) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (initialized) revert PoolAlreadyInitialized();
        if (initialDeposit_ != expectedInitialDeposit) revert InitialDepositMismatch();
        initialized = true;

        uint256 bullDeposit = initialDeposit_ / 2;
        uint256 bearDeposit = initialDeposit_ - bullDeposit;
        if (initialDeposit_ > 0) {
            baseToken.safeTransferFrom(msg.sender, address(this), initialDeposit_);
            baseToken.safeTransfer(address(bullCoin), bullDeposit);
            baseToken.safeTransfer(address(bearCoin), bearDeposit);

            uint8 decimals_ = IERC20Metadata(address(baseToken)).decimals();
            uint256 scale = 10 ** (18 - decimals_);
            bullCoin.mintInitialSupply(bullDeposit * scale);
            bearCoin.mintInitialSupply(bearDeposit * scale);
        }

        emit PoolInitialized(
            vaultCreator, initialDeposit_, bullDeposit, bearDeposit, block.timestamp
        );
    }

    function updateOracle(address newOracle) external onlyOwner {
        _checkOracle(newOracle);
        address previousOracle = address(oracle);
        oracle = IOracle(newOracle);
        uint256 currentPrice = IOracle(newOracle).readValue();
        // A different oracle must not inherit the old oracle's price as its baseline.
        if (currentPrice > 0 || newOracle != previousOracle) previousPrice = currentPrice;
        emit OracleUpdated(previousOracle, newOracle);
    }

    function rebalance() external {
        uint256 newPrice = oracle.readValue();
        if (newPrice == 0) return;

        uint256 oldPrice = previousPrice;
        if (oldPrice == 0) {
            previousPrice = newPrice;
            return;
        }
        if (newPrice == oldPrice) return;

        uint256 bullBefore = baseToken.balanceOf(address(bullCoin));
        uint256 bearBefore = baseToken.balanceOf(address(bearCoin));
        uint256 totalReserves = bullBefore + bearBefore;
        if (totalReserves == 0) {
            previousPrice = newPrice;
            return;
        }

        uint256 adjustedBull = Math.mulDiv(bullBefore, newPrice, oldPrice);
        uint256 adjustedBear = Math.mulDiv(bearBefore, oldPrice, newPrice);
        uint256 denominator = adjustedBull + adjustedBear;
        if (denominator == 0) return;

        uint256 bullTarget = Math.mulDiv(totalReserves, adjustedBull, denominator);
        uint256 transferAmount;
        bool toBull = bullTarget > bullBefore;
        if (toBull) {
            transferAmount = bullTarget - bullBefore;
            bearCoin.transferReserveToOther(transferAmount);
        } else if (bullTarget < bullBefore) {
            transferAmount = bullBefore - bullTarget;
            bullCoin.transferReserveToOther(transferAmount);
        }

        uint256 percentChange = Math.mulDiv(
            newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice, 10_000, oldPrice
        );
        previousPrice = newPrice;
        emit Rebalanced(
            msg.sender,
            block.number,
            oldPrice,
            newPrice,
            percentChange,
            bullBefore,
            bearBefore,
            baseToken.balanceOf(address(bullCoin)),
            baseToken.balanceOf(address(bearCoin)),
            transferAmount,
            toBull,
            block.timestamp
        );
    }

    function getCurrentPrice() external view returns (uint256) {
        return oracle.readValue();
    }

    function getPoolCounters()
        external
        view
        returns (uint256 cumulativeVolume, uint256 cumulativeFees, uint256 tradeCount_)
    {
        cumulativeVolume = bullCoin.cumulativeVolume() + bearCoin.cumulativeVolume();
        cumulativeFees = bullCoin.cumulativeFees() + bearCoin.cumulativeFees();
        tradeCount_ = bullCoin.tradeCount() + bearCoin.tradeCount();
    }

    function getPoolStats()
        external
        view
        returns (
            uint256 bullReserves,
            uint256 bearReserves,
            uint256 totalReserves,
            uint256 currentPrice,
            uint256 lastPrice
        )
    {
        bullReserves = baseToken.balanceOf(address(bullCoin));
        bearReserves = baseToken.balanceOf(address(bearCoin));
        totalReserves = bullReserves + bearReserves;
        currentPrice = oracle.readValue();
        lastPrice = previousPrice;
    }

    function _checkOracle(address oracle_) internal view {
        if (oracle_ == address(0) || oracle_.code.length == 0) revert InvalidOracle();
        try IOracle(oracle_).readValue() returns (uint256) { }
        catch { revert InvalidOracle(); }
    }

}
