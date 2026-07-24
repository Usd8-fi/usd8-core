// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IProfitDistributionReceiver} from "../../src/interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

contract TreasuryAclPauseToken is ERC20 {
    uint8 internal immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Honest push-deposit/exact-withdraw strategy. Counters make rejected calls nonvacuous.
contract TreasuryAclPauseStrategy is IStrategy {
    IERC20 public immutable asset;
    uint256 public deployCalls;
    uint256 public withdrawCalls;
    uint256 public lastDeployAmount;
    uint256 public lastWithdrawAmount;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function underlying() external view returns (address) {
        return address(asset);
    }

    function deploy(uint256 amount) external {
        require(asset.balanceOf(address(this)) >= amount, "assets not pushed");
        deployCalls++;
        lastDeployAmount = amount;
    }

    function withdraw(uint256 amount) external {
        withdrawCalls++;
        lastWithdrawAmount = amount;
        require(asset.transfer(msg.sender, amount), "transfer failed");
    }

    function totalAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/// @dev Honest hook receiver that pulls exactly the approved distribution.
contract TreasuryAclPauseReceiver is IProfitDistributionReceiver {
    IERC20 public immutable token;
    uint256 public receiveCalls;
    uint256 public totalReceived;

    constructor(IERC20 token_) {
        token = token_;
    }

    function receiveProfitDistribution(uint256 amount) external {
        receiveCalls++;
        totalReceived += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
    }
}

contract TreasuryAclPauseV2 is Treasury {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Focused symbolic properties for Registry-mediated Treasury ACL and pause boundaries.
/// @dev Registry, USD8, and Treasury are production implementations behind real ERC1967 proxies.
///      Symbolic callers use vm.prank. Successful value-bearing paths use uint64 amounts so all
///      reserve scaling is comfortably inside uint256. Each rejected path snapshots its relevant
///      arrays, balances, supply, implementation slot, and/or external helper counters.
contract TreasuryAclPauseKontrolTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant SCALE = 1e12;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    address internal constant NEW_ADMIN = address(0xC0FFEE);
    address internal constant NEW_TIMELOCK = address(0xD00D);
    address internal constant RECIPIENT = address(0xCAFE);

    struct OperationSnapshot {
        uint256 idle;
        uint256 strategyAssets;
        uint256 deployCalls;
        uint256 withdrawCalls;
        uint256 supply;
        uint256 receiverBalance;
    }

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryAclPauseToken internal usdc;

    function setUp() public {
        usdc = new TreasuryAclPauseToken("Kontrol USDC", "kUSDC", 6);
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(treasury), IMPLEMENTATION_SLOT);
    }

    function _assumeUnauthorized(address caller) internal view {
        vm.assume(caller != registry.timelock());
        vm.assume(!registry.isAdmin(caller));
    }

    function _callAs(address caller, bytes memory data) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(treasury).call(data);
    }

    function _approveStrategy(TreasuryAclPauseStrategy strategy) internal {
        treasury.addStrategy(strategy, type(uint256).max);
    }

    function _mintForUser(uint64 amount) internal {
        vm.assume(amount > 0);
        usdc.mint(USER, amount);
        vm.startPrank(USER);
        usdc.approve(address(treasury), amount);
        treasury.mintUSD8(amount);
        vm.stopPrank();
    }

    function _setDirectReceiver(address receiver) internal {
        treasury.setProfitReceiver(receiver, 1, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_unauthorizedCallerCannotAddOrRemoveStrategiesAtomically(address caller) public {
        _assumeUnauthorized(caller);
        TreasuryAclPauseStrategy approved = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseStrategy candidate = new TreasuryAclPauseStrategy(usdc);
        _approveStrategy(approved);

        (bool addSuccess, bytes memory addData) =
            _callAs(caller, abi.encodeCall(Treasury.addStrategy, (IStrategy(address(candidate)), uint256(0))));
        assert(!addSuccess);
        assert(_selector(addData) == Registry.UnauthorizedTimelock.selector);
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(approved));

        (bool removeSuccess, bytes memory removeData) =
            _callAs(caller, abi.encodeCall(Treasury.removeStrategy, (IStrategy(address(approved)))));
        assert(!removeSuccess);
        assert(_selector(removeData) == Registry.UnauthorizedTimelock.selector);
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(approved));
    }

    function test_unauthorizedCallerCannotDepositWithdrawOrHarvestAtomically(address caller, uint64 amount) public {
        _assumeUnauthorized(caller);
        vm.assume(amount > 0);
        TreasuryAclPauseStrategy strategy = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseReceiver receiver = new TreasuryAclPauseReceiver(usd8);
        _approveStrategy(strategy);
        _setDirectReceiver(address(receiver));
        usdc.mint(address(treasury), uint256(amount) * 2);
        treasury.depositToStrategy(strategy, amount);

        OperationSnapshot memory before_ = OperationSnapshot({
            idle: usdc.balanceOf(address(treasury)),
            strategyAssets: usdc.balanceOf(address(strategy)),
            deployCalls: strategy.deployCalls(),
            withdrawCalls: strategy.withdrawCalls(),
            supply: usd8.totalSupply(),
            receiverBalance: usd8.balanceOf(address(receiver))
        });

        {
            (bool success, bytes memory data) = _callAs(
                caller, abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(amount)))
            );
            assert(!success);
            assert(_selector(data) == Registry.UnauthorizedAdmin.selector);
        }
        {
            (bool success, bytes memory data) = _callAs(
                caller, abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(amount)))
            );
            assert(!success);
            assert(_selector(data) == Registry.UnauthorizedAdmin.selector);
        }
        {
            (bool success, bytes memory data) = _callAs(caller, abi.encodeCall(Treasury.harvestAndDistribute, ()));
            assert(!success);
            assert(_selector(data) == Registry.UnauthorizedAdmin.selector);
        }
        assert(usdc.balanceOf(address(treasury)) == before_.idle);
        assert(usdc.balanceOf(address(strategy)) == before_.strategyAssets);
        assert(strategy.deployCalls() == before_.deployCalls);
        assert(strategy.withdrawCalls() == before_.withdrawCalls);
        assert(usd8.totalSupply() == before_.supply);
        assert(usd8.balanceOf(address(receiver)) == before_.receiverBalance);
        assert(receiver.receiveCalls() == 0);
    }

    function test_unauthorizedCallerCannotSetOrRemoveReceiverAtomically(address caller, uint64 weight) public {
        _assumeUnauthorized(caller);
        TreasuryAclPauseReceiver existing = new TreasuryAclPauseReceiver(usd8);
        TreasuryAclPauseReceiver candidate = new TreasuryAclPauseReceiver(usd8);
        _setDirectReceiver(address(existing));

        (bool setSuccess, bytes memory setData) = _callAs(
            caller,
            abi.encodeCall(
                Treasury.setProfitReceiver,
                (address(candidate), uint256(weight), Treasury.RevenueDistributionMode.ReceiveProfitDistribution)
            )
        );
        assert(!setSuccess);
        assert(_selector(setData) == Registry.UnauthorizedAdmin.selector);

        (bool removeSuccess, bytes memory removeData) =
            _callAs(caller, abi.encodeCall(Treasury.removeProfitReceiver, (address(existing))));
        assert(!removeSuccess);
        assert(_selector(removeData) == Registry.UnauthorizedAdmin.selector);
        assert(treasury.profitReceiversLength() == 1);
        (address receiver, uint256 savedWeight, Treasury.RevenueDistributionMode mode) = treasury.profitReceivers(0);
        assert(receiver == address(existing));
        assert(savedWeight == 1);
        assert(mode == Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_unauthorizedCallerCannotSweepTokenOrETHAtomically(
        address caller,
        address payable recipient,
        uint128 tokenAmount,
        uint128 ethAmount
    ) public {
        _assumeUnauthorized(caller);
        vm.assume(recipient != address(treasury));
        vm.assume(tokenAmount > 0 && ethAmount > 0);
        TreasuryAclPauseToken foreignToken = new TreasuryAclPauseToken("Foreign", "FOR", 18);
        foreignToken.mint(address(treasury), tokenAmount);
        vm.deal(address(treasury), ethAmount);
        uint256 tokenRecipientBefore = foreignToken.balanceOf(recipient);
        uint256 ethRecipientBefore = recipient.balance;

        (bool tokenSuccess, bytes memory tokenData) =
            _callAs(caller, abi.encodeCall(SharedBase.sweepToken, (IERC20(address(foreignToken)), address(recipient))));
        assert(!tokenSuccess);
        assert(_selector(tokenData) == Registry.UnauthorizedAdmin.selector);

        (bool ethSuccess, bytes memory ethData) = _callAs(caller, abi.encodeCall(SharedBase.sweepETH, (recipient)));
        assert(!ethSuccess);
        assert(_selector(ethData) == Registry.UnauthorizedAdmin.selector);
        assert(foreignToken.balanceOf(address(treasury)) == tokenAmount);
        assert(foreignToken.balanceOf(recipient) == tokenRecipientBefore);
        assert(address(treasury).balance == ethAmount);
        assert(recipient.balance == ethRecipientBefore);
    }

    function test_unauthorizedCallerCannotUpgradeAtomically(address caller) public {
        vm.assume(caller != registry.timelock());
        TreasuryAclPauseV2 candidate = new TreasuryAclPauseV2();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            _callAs(caller, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == implementationBefore);
        assert(address(treasury.registry()) == address(registry));
        assert(address(treasury.USDC()) == address(usdc));
    }

    function test_adminOperationalAuthorityDoesNotGrantTimelockCurationOrUpgrade(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryAclPauseStrategy approved = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseStrategy candidate = new TreasuryAclPauseStrategy(usdc);
        _approveStrategy(approved);
        usdc.mint(address(treasury), amount);

        vm.prank(ADMIN);
        treasury.depositToStrategy(approved, amount);
        assert(approved.deployCalls() == 1);
        assert(usdc.balanceOf(address(approved)) == amount);

        vm.prank(ADMIN);
        treasury.withdrawFromStrategy(approved, amount);
        assert(approved.withdrawCalls() == 1);
        assert(approved.lastWithdrawAmount() == amount);
        assert(usdc.balanceOf(address(approved)) == 0);
        assert(usdc.balanceOf(address(treasury)) == amount);

        _setDirectReceiver(RECIPIENT);
        vm.prank(ADMIN);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        uint256 expectedRevenue = uint256(amount) * SCALE;
        assert(harvested == expectedRevenue);
        assert(distributed == expectedRevenue);
        assert(usd8.balanceOf(RECIPIENT) == expectedRevenue);
        assert(usd8.balanceOf(address(treasury)) == 0);

        (bool addSuccess, bytes memory addData) =
            _callAs(ADMIN, abi.encodeCall(Treasury.addStrategy, (IStrategy(address(candidate)), uint256(0))));
        assert(!addSuccess);
        assert(_selector(addData) == Registry.UnauthorizedTimelock.selector);

        TreasuryAclPauseV2 upgradeCandidate = new TreasuryAclPauseV2();
        bytes32 implementationBefore = _implementationWord();
        (bool upgradeSuccess, bytes memory upgradeData) =
            _callAs(ADMIN, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(upgradeCandidate), bytes(""))));
        assert(!upgradeSuccess);
        assert(_selector(upgradeData) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == implementationBefore);
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(approved));
    }

    function test_adminRotationImmediatelyRevokesOldAndGrantsNew() public {
        registry.setAdmin(NEW_ADMIN, true);
        registry.setAdmin(ADMIN, false);
        TreasuryAclPauseReceiver oldAttempt = new TreasuryAclPauseReceiver(usd8);
        TreasuryAclPauseReceiver accepted = new TreasuryAclPauseReceiver(usd8);

        (bool oldSuccess, bytes memory oldData) = _callAs(
            ADMIN,
            abi.encodeCall(
                Treasury.setProfitReceiver,
                (address(oldAttempt), uint256(1), Treasury.RevenueDistributionMode.DirectTransfer)
            )
        );
        assert(!oldSuccess);
        assert(_selector(oldData) == Registry.UnauthorizedAdmin.selector);
        assert(treasury.profitReceiversLength() == 0);

        vm.prank(NEW_ADMIN);
        treasury.setProfitReceiver(address(accepted), 1, Treasury.RevenueDistributionMode.DirectTransfer);
        assert(treasury.profitReceiversLength() == 1);
        (address saved,,) = treasury.profitReceivers(0);
        assert(saved == address(accepted));
    }

    function test_timelockRotationImmediatelyRevokesOldAndGrantsNew() public {
        registry.setTimelock(NEW_TIMELOCK);
        TreasuryAclPauseStrategy oldAttempt = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseStrategy accepted = new TreasuryAclPauseStrategy(usdc);

        (bool oldSuccess, bytes memory oldData) =
            address(treasury).call(abi.encodeCall(Treasury.addStrategy, (IStrategy(address(oldAttempt)), uint256(0))));
        assert(!oldSuccess);
        assert(_selector(oldData) == Registry.UnauthorizedTimelock.selector);
        assert(treasury.strategiesLength() == 0);

        vm.prank(NEW_TIMELOCK);
        treasury.addStrategy(accepted, 0);
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(accepted));
    }

    function test_pauseBlocksMintAndRedeemBeforeMutation(uint64 initialAmount, uint64 mintAttempt, uint64 redeemAttempt)
        public
    {
        vm.assume(initialAmount > 0 && mintAttempt > 0);
        _mintForUser(initialAmount);
        vm.assume(redeemAttempt > 0 && uint256(redeemAttempt) * SCALE <= usd8.balanceOf(USER));
        usdc.mint(USER, mintAttempt);
        vm.prank(USER);
        usdc.approve(address(treasury), mintAttempt);
        registry.setPaused(address(treasury), true);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 userUsd8Before = usd8.balanceOf(USER);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 allowanceBefore = usdc.allowance(USER, address(treasury));

        (bool mintSuccess, bytes memory mintData) =
            _callAs(USER, abi.encodeCall(Treasury.mintUSD8, (uint256(mintAttempt))));
        assert(!mintSuccess);
        assert(_selector(mintData) == Registry.Paused.selector);

        (bool redeemSuccess, bytes memory redeemData) =
            _callAs(USER, abi.encodeCall(Treasury.redeemUSD8, (uint256(redeemAttempt) * SCALE, uint256(redeemAttempt))));
        assert(!redeemSuccess);
        assert(_selector(redeemData) == Registry.Paused.selector);
        assert(usdc.balanceOf(address(treasury)) == idleBefore);
        assert(usdc.balanceOf(USER) == userUsdcBefore);
        assert(usd8.balanceOf(USER) == userUsd8Before);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usdc.allowance(USER, address(treasury)) == allowanceBefore);
    }

    function test_pauseBlocksStrategyDepositWithdrawAndHarvestBeforeMutation(uint64 amount) public {
        vm.assume(amount > 0);
        TreasuryAclPauseStrategy strategy = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseReceiver receiver = new TreasuryAclPauseReceiver(usd8);
        _approveStrategy(strategy);
        _setDirectReceiver(address(receiver));
        usdc.mint(address(treasury), uint256(amount) * 2);
        treasury.depositToStrategy(strategy, amount);
        registry.setPaused(address(treasury), true);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 strategyBefore = usdc.balanceOf(address(strategy));
        uint256 supplyBefore = usd8.totalSupply();
        uint256 deployCallsBefore = strategy.deployCalls();
        uint256 withdrawCallsBefore = strategy.withdrawCalls();

        (bool depositSuccess, bytes memory depositData) = address(treasury)
            .call(abi.encodeCall(Treasury.depositToStrategy, (IStrategy(address(strategy)), uint256(amount))));
        assert(!depositSuccess);
        assert(_selector(depositData) == Registry.Paused.selector);

        (bool withdrawSuccess, bytes memory withdrawData) = address(treasury)
            .call(abi.encodeCall(Treasury.withdrawFromStrategy, (IStrategy(address(strategy)), uint256(amount))));
        assert(!withdrawSuccess);
        assert(_selector(withdrawData) == Registry.Paused.selector);

        (bool harvestSuccess, bytes memory harvestData) =
            address(treasury).call(abi.encodeCall(Treasury.harvestAndDistribute, ()));
        assert(!harvestSuccess);
        assert(_selector(harvestData) == Registry.Paused.selector);
        assert(usdc.balanceOf(address(treasury)) == idleBefore);
        assert(usdc.balanceOf(address(strategy)) == strategyBefore);
        assert(strategy.deployCalls() == deployCallsBefore);
        assert(strategy.withdrawCalls() == withdrawCallsBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(receiver.receiveCalls() == 0);
    }

    function test_pauseIntentionallyAllowsStrategyAndReceiverCuration(uint64 weight) public {
        vm.assume(weight > 0);
        TreasuryAclPauseStrategy first = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseStrategy second = new TreasuryAclPauseStrategy(usdc);
        TreasuryAclPauseReceiver receiver = new TreasuryAclPauseReceiver(usd8);
        _approveStrategy(first);
        registry.setPaused(address(treasury), true);

        treasury.addStrategy(second, 0);
        treasury.removeStrategy(first);
        treasury.setProfitReceiver(
            address(receiver), weight, Treasury.RevenueDistributionMode.ReceiveProfitDistribution
        );
        treasury.removeProfitReceiver(address(receiver));

        assert(registry.paused(address(treasury)));
        assert(treasury.strategiesLength() == 1);
        assert(address(treasury.strategies(0)) == address(second));
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_pauseIntentionallyAllowsSweepsAndUpgrade(uint128 tokenAmount, uint128 ethAmount) public {
        vm.assume(tokenAmount > 0 && ethAmount > 0);
        TreasuryAclPauseToken foreignToken = new TreasuryAclPauseToken("Foreign", "FOR", 18);
        foreignToken.mint(address(treasury), tokenAmount);
        vm.deal(address(treasury), ethAmount);
        registry.setPaused(address(treasury), true);
        TreasuryAclPauseV2 candidate = new TreasuryAclPauseV2();

        treasury.sweepToken(IERC20(address(foreignToken)), RECIPIENT);
        treasury.sweepETH(payable(RECIPIENT));
        treasury.upgradeToAndCall(address(candidate), "");

        assert(registry.paused(address(treasury)));
        assert(foreignToken.balanceOf(address(treasury)) == 0);
        assert(foreignToken.balanceOf(RECIPIENT) == tokenAmount);
        assert(address(treasury).balance == 0);
        assert(TreasuryAclPauseV2(address(treasury)).version() == 2);
        assert(_implementationWord() == bytes32(uint256(uint160(address(candidate)))));
    }

    function test_unpauseItselfPreservesStateAndRestoresRepresentativeGatedPaths(
        uint64 mintAmount,
        uint64 strategyAmount
    ) public {
        vm.assume(mintAmount > 0 && strategyAmount > 0);
        TreasuryAclPauseStrategy strategy = new TreasuryAclPauseStrategy(usdc);
        _approveStrategy(strategy);
        usdc.mint(USER, mintAmount);
        vm.prank(USER);
        usdc.approve(address(treasury), mintAmount);
        usdc.mint(address(treasury), strategyAmount);
        registry.setPaused(address(treasury), true);

        uint256 idleBefore = usdc.balanceOf(address(treasury));
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 allowanceBefore = usdc.allowance(USER, address(treasury));
        assert(strategy.deployCalls() == 0);

        registry.setPaused(address(treasury), false);
        assert(usdc.balanceOf(address(treasury)) == idleBefore);
        assert(usdc.balanceOf(USER) == userUsdcBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usdc.allowance(USER, address(treasury)) == allowanceBefore);
        assert(strategy.deployCalls() == 0);

        vm.prank(USER);
        treasury.mintUSD8(mintAmount);
        treasury.depositToStrategy(strategy, strategyAmount);
        assert(usd8.balanceOf(USER) == uint256(mintAmount) * SCALE);
        assert(usd8.totalSupply() == uint256(mintAmount) * SCALE);
        assert(usdc.balanceOf(address(strategy)) == strategyAmount);
        assert(strategy.deployCalls() == 1);
        assert(!registry.paused(address(treasury)));
    }

    function test_unpauseRestoresRedeemWithdrawalAndHarvest() public {
        uint64 minted = 10e6;
        uint64 allocated = 4e6;
        uint64 redeemed = 1e6;
        uint64 manualWithdrawal = 1e6;
        TreasuryAclPauseStrategy strategy = new TreasuryAclPauseStrategy(usdc);
        _approveStrategy(strategy);
        _mintForUser(minted);
        treasury.depositToStrategy(strategy, allocated);
        usdc.mint(address(treasury), 2e6);
        _setDirectReceiver(RECIPIENT);
        registry.setPaused(address(treasury), true);

        registry.setPaused(address(treasury), false);
        vm.prank(USER);
        treasury.redeemUSD8(uint256(redeemed) * SCALE, redeemed);
        treasury.withdrawFromStrategy(strategy, manualWithdrawal);
        uint256 supplyBeforeHarvest = usd8.totalSupply();
        uint256 reserveBeforeHarvest = treasury.getReserveBalance();
        uint256 expectedHarvest = reserveBeforeHarvest * SCALE - supplyBeforeHarvest - supplyBeforeHarvest
            / treasury.HARVEST_BUFFER_DIVISOR();
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();

        assert(!registry.paused(address(treasury)));
        assert(usdc.balanceOf(USER) == redeemed);
        assert(strategy.withdrawCalls() == 1);
        assert(strategy.lastWithdrawAmount() == manualWithdrawal);
        assert(harvested == expectedHarvest && distributed == expectedHarvest);
        assert(usd8.balanceOf(RECIPIENT) == expectedHarvest);
        assert(usd8.balanceOf(address(treasury)) == 0);
    }
}
