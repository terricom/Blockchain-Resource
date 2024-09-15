// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "../lib/forge-std/src/console.sol";
import { CErc20Delegator } from "../lib/compound-protocol/contracts/CErc20Delegator.sol";
import { CErc20Delegate } from "../lib/compound-protocol/contracts/CErc20Delegate.sol";
import { ComptrollerInterface } from "../lib/compound-protocol/contracts/ComptrollerInterface.sol";
import { CToken } from "../lib/compound-protocol/contracts/CToken.sol";
import { Comptroller } from "../lib/compound-protocol/contracts/Comptroller.sol";
import { Unitroller } from "../lib/compound-protocol/contracts/Unitroller.sol";
import { WhitePaperInterestRateModel } from "../lib/compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import { SimplePriceOracle } from "../lib/compound-protocol/contracts/SimplePriceOracle.sol";
import { TestERC20 } from "../contracts/test/TestERC20.sol";
import "../test/helper/CompoundPracticeSetUp.sol";

contract MyCompoundTest is CompoundPracticeSetUp {

    Comptroller comptroller;
    Unitroller unitroller;
    SimplePriceOracle simpleOracle;
    WhitePaperInterestRateModel interestRateModel; 

    TestERC20 tokenA;
    TestERC20 tokenB;

    CErc20Delegate delegateA;
    CErc20Delegator delegatorA;

    CErc20Delegate delegateB;
    CErc20Delegator delegatorB;

    address public user1;
    address public user2;
    
  function setUp() public override {
    comptroller = new Comptroller();
    unitroller = new Unitroller();
    unitroller._setPendingImplementation(address(comptroller));

    comptroller._become(unitroller);
    simpleOracle = new SimplePriceOracle();
    Comptroller(address(unitroller))._setPriceOracle(simpleOracle);
    interestRateModel = new WhitePaperInterestRateModel(0, 0); 

    tokenA = new TestERC20("token A", "TKA");
    bytes memory dataA;
    delegateA = new CErc20Delegate();
    delegatorA = new CErc20Delegator(address(tokenA), ComptrollerInterface(address(unitroller)), interestRateModel, 1e18, "cTokenA", "cTokenA", 18, payable(msg.sender), address(delegateA), dataA);
    Comptroller(address(unitroller))._supportMarket(CToken(address(delegatorA)));
    simpleOracle.setUnderlyingPrice(CToken(address(delegatorA)), 1 * 1e18);

    tokenB = new TestERC20("token B", "TKB");
    bytes memory dataB;
    delegateB = new CErc20Delegate();
    delegatorB = new CErc20Delegator(address(tokenB), ComptrollerInterface(address(unitroller)), interestRateModel, 1e18, "cTokenB", "cTokenB", 18, payable(msg.sender), address(delegateB), dataB);
    Comptroller(address(unitroller))._supportMarket(CToken(address(delegatorB)));
    simpleOracle.setUnderlyingPrice(CToken(address(delegatorB)), 100 * 1e18);
    Comptroller(address(unitroller))._setCollateralFactor(CToken(address(delegatorB)), 5 * 1e17);

    Comptroller(address(unitroller))._setCloseFactor(5 * 1e17);
    Comptroller(address(unitroller))._setLiquidationIncentive(108 * 1e16);

    user1 = makeAddr("User1");
    user2 = makeAddr("User2");
  }

  function test_user1_mint_redeem() public {
    uint decimal = tokenA.decimals();
    uint initialBalance = 1000 * 10 ** decimal;
    deal(address(tokenA), user1, initialBalance);
    vm.startPrank(user1);
    uint supply = 100 * 10 ** decimal; 
    // approve underlying tokenA
    tokenA.approve(address(delegatorA), supply);
    // supply underlying tokenA
    delegatorA.mint(supply);
    // assert get 100 cTokenA
    assertEq(delegatorA.balanceOf(user1), supply);
    // redeem underlying tokenA
    delegatorA.redeemUnderlying(supply);
    // assert user1 redeem tokenA to initial balance
    assertEq(tokenA.balanceOf(user1), initialBalance);
    vm.stopPrank();
  }

  function test_user1_borrow_rapay() public {
    uint decimalB = tokenB.decimals();
    uint initialBalanceB = 1000 * 10 ** decimalB;
    deal(address(tokenB), user1, initialBalanceB);
    vm.startPrank(user1);
    uint supply = 1 * 10 ** decimalB; 
    // approve underlying tokenB
    tokenB.approve(address(delegatorB), supply);
    // supply underlying tokenB
    delegatorB.mint(supply);
    // assert get 1 cTokenB
    assertEq(delegatorB.balanceOf(user1), supply);
    
    address[] memory addr = new address[](1);
    addr[0] = address(delegatorB);
    Comptroller(address(unitroller)).enterMarkets(addr);

    uint decimalA = tokenA.decimals();
    uint borrow = 50 * 10 ** decimalA;
    // provide cTokenA for borrow
    deal(address(tokenA), address(delegatorA), 1000 * 10 ** decimalA);
    // borrow 50 tokenA
    delegatorA.borrow(borrow);
    // assert get 50 tokenA
    assertEq(tokenA.balanceOf(user1), borrow);
    // approve underlying tokenA
    tokenA.approve(address(delegatorA), borrow);
    // repay borrow
    delegatorA.repayBorrow(borrow);
    // assert return 50 tokenA
    assertEq(tokenA.balanceOf(user1), 0);
    vm.stopPrank();
  }

  function test_tokenB_collateral_factor_liquidate() public {
    uint decimalB = tokenB.decimals();
    uint initialBalanceB = 1000 * 10 ** decimalB;
    deal(address(tokenB), user1, initialBalanceB);
    vm.startPrank(user1);
    uint supply = 1 * 10 ** decimalB; 
    // approve underlying tokenB
    tokenB.approve(address(delegatorB), supply);
    // supply underlying tokenB
    delegatorB.mint(supply);
    // assert get 1 cTokenB
    assertEq(delegatorB.balanceOf(user1), supply);
    
    address[] memory addr = new address[](1);
    addr[0] = address(delegatorB);
    Comptroller(address(unitroller)).enterMarkets(addr);

    uint decimalA = tokenA.decimals();
    uint borrow = 50 * 10 ** decimalA;
    // provide cTokenA for borrow
    deal(address(tokenA), address(delegatorA), 1000 * 10 ** decimalA);
    // borrow 50 tokenA
    delegatorA.borrow(borrow);
    // assert get 50 tokenA
    assertEq(tokenA.balanceOf(user1), borrow);
    vm.stopPrank();
    
    // change collateral factor to 30%
    Comptroller(address(unitroller))._setCollateralFactor(CToken(address(delegatorB)), 3 * 1e17);

    deal(address(tokenA), user2, 1000 * 10 ** decimalA);
    deal(address(tokenB), user2, 1000 * 10 ** decimalB);
    vm.startPrank(user2);
    // approve underlying tokenA
    tokenA.approve(address(delegatorA), 1000 * 10 ** decimalA);
    // liquidate borrow tokenA
    delegatorA.liquidateBorrow(user1, 25 * 10 ** decimalA, delegatorB);
    // assert user1 get zero shortfall
    (,, uint256 shortfall) = Comptroller(address(unitroller)).getAccountLiquidity(user1);
    // get expected from tokenA debt - (tokenB price - tokenB liquidation) * tokenB collateral factor
    uint expected = 25 * 1e18 - (100 * 1e18 - 25 * 1.08 * 1e18) * 0.3;
    // assert shortfall 3 (rundown to 1e18)
    assertEq(expected / 1e18, shortfall / 1e18);
    
    vm.stopPrank();
  }

  function test_tokenB_oracle_price_liquidate() public {
    uint decimalB = tokenB.decimals();
    uint initialBalanceB = 1000 * 10 ** decimalB;
    deal(address(tokenB), user1, initialBalanceB);
    vm.startPrank(user1);
    uint supply = 1 * 10 ** decimalB; 
    // approve underlying tokenB
    tokenB.approve(address(delegatorB), supply);
    // supply underlying tokenB
    delegatorB.mint(supply);
    // assert get 1 cTokenB
    assertEq(delegatorB.balanceOf(user1), supply);
    
    address[] memory addr = new address[](1);
    addr[0] = address(delegatorB);
    Comptroller(address(unitroller)).enterMarkets(addr);

    uint decimalA = tokenA.decimals();
    uint borrow = 50 * 10 ** decimalA;
    // provide cTokenA for borrow
    deal(address(tokenA), address(delegatorA), 1000 * 10 ** decimalA);
    // borrow 50 tokenA
    delegatorA.borrow(borrow);
    // assert get 50 tokenA
    assertEq(tokenA.balanceOf(user1), borrow);
    vm.stopPrank();
    
    // change Oracle price to 70
    simpleOracle.setUnderlyingPrice(CToken(address(delegatorB)), 70 * 1e18);

    deal(address(tokenA), user2, 1000 * 10 ** decimalA);
    deal(address(tokenB), user2, 1000 * 10 ** decimalB);
    vm.startPrank(user2);
    // approve underlying tokenA
    tokenA.approve(address(delegatorA), 1000 * 10 ** decimalA);
    // liquidate borrow tokenA
    delegatorA.liquidateBorrow(user1, 25 * 10 ** decimalA, delegatorB);
    // assert user1 get zero shortfall
    (,, uint256 shortfall) = Comptroller(address(unitroller)).getAccountLiquidity(user1);
    // get expected from tokenA debt - (tokenB price - tokenB liquidation) * tokenB collateral factor
    uint expected = 25 * 1e18 - (70 * 1e18 - 25 * 1.08 * 1e18) * 0.5;
    // assert shortfall 3 (rundown to 1e18)
    assertEq(expected / 1e18, shortfall / 1e18);
    
    vm.stopPrank();
  }
}
