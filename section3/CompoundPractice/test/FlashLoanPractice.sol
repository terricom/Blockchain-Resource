// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import "../lib/forge-std/src/console.sol";
import "../lib/forge-std/src/Test.sol";
import { CErc20Delegator } from "../lib/compound-protocol/contracts/CErc20Delegator.sol";
import { CErc20Delegate } from "../lib/compound-protocol/contracts/CErc20Delegate.sol";
import { ComptrollerInterface } from "../lib/compound-protocol/contracts/ComptrollerInterface.sol";
import { CToken } from "../lib/compound-protocol/contracts/CToken.sol";
import { CErc20 } from "../lib/compound-protocol/contracts/CErc20.sol";
import { Comptroller } from "../lib/compound-protocol/contracts/Comptroller.sol";
import { Unitroller } from "../lib/compound-protocol/contracts/Unitroller.sol";
import { WhitePaperInterestRateModel } from "../lib/compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import { SimplePriceOracle } from "../lib/compound-protocol/contracts/SimplePriceOracle.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
  IFlashLoanSimpleReceiver,
  IPoolAddressesProvider,
  IPool
} from "../lib/aave-v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import "../lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract FlashLoanPracticeTest is Test, IFlashLoanSimpleReceiver {

    Comptroller comptroller;
    Unitroller unitroller;
    SimplePriceOracle simpleOracle;
    WhitePaperInterestRateModel interestRateModel; 

    address constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    ERC20 USDC;
    ERC20 UNI;

    CErc20Delegator cUSDC;
    CErc20Delegator cUNI;

    address public user1;
    address public user2;
    
  function setUp() public {
    uint256 forkId = vm.createFork("https://eth-mainnet.g.alchemy.com/v2/-CmqkVjFZ7gnwUdbfGpt_dasLBkBR1ds", 17465000);
    vm.selectFork(forkId);

    comptroller = new Comptroller();
    unitroller = new Unitroller();
    unitroller._setPendingImplementation(address(comptroller));

    comptroller._become(unitroller);
    simpleOracle = new SimplePriceOracle();
    Comptroller(address(unitroller))._setPriceOracle(simpleOracle);
    interestRateModel = new WhitePaperInterestRateModel(0, 0); 

    USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    bytes memory dataA;
    CErc20Delegate cUSDCDelegate = new CErc20Delegate();
    cUSDC = new CErc20Delegator(address(USDC), ComptrollerInterface(address(unitroller)), interestRateModel, 1e18, "cUSDC", "cUSDC", 18, payable(msg.sender), address(cUSDCDelegate), dataA);
    Comptroller(address(unitroller))._supportMarket(CToken(address(cUSDC)));
    simpleOracle.setUnderlyingPrice(CToken(address(cUSDC)), 1 * 1e30);

    UNI = ERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    bytes memory dataB;
    CErc20Delegate cUNIDelegate = new CErc20Delegate();
    cUNI = new CErc20Delegator(address(UNI), ComptrollerInterface(address(unitroller)), interestRateModel, 1e18, "cUNI", "cUNI", 18, payable(msg.sender), address(cUNIDelegate), dataB);
    Comptroller(address(unitroller))._supportMarket(CToken(address(cUNI)));
    simpleOracle.setUnderlyingPrice(CToken(address(cUNI)), 5 * 1e18);
    Comptroller(address(unitroller))._setCollateralFactor(CToken(address(cUNI)), 5 * 1e17);

    Comptroller(address(unitroller))._setCloseFactor(5 * 1e17);
    Comptroller(address(unitroller))._setLiquidationIncentive(108 * 1e16);

    user1 = makeAddr("User1");
    user2 = makeAddr("User2");

  }

  function test_UNI_oracle_price_liquidate() public {
    uint borrow = 2500 * 10 ** USDC.decimals();
    uint supply = 1000 * 10 ** UNI.decimals(); 
    // provide cUSDC for borrow
    deal(address(USDC), address(cUSDC), borrow);

    // provide user1 UNI
    deal(address(UNI), user1, supply);

    vm.startPrank(user1);
    // approve underlying UNI
    UNI.approve(address(cUNI), supply);
    // supply underlying UNI
    cUNI.mint(supply);
    // assert get supply cUNI
    assertEq(cUNI.balanceOf(user1), supply);
    
    // provide cUNI to market
    address[] memory addr = new address[](1);
    addr[0] = address(cUNI);
    Comptroller(address(unitroller)).enterMarkets(addr);

    // borrow USDC
    cUSDC.borrow(borrow);
    // assert get borrow USDC
    assertEq(USDC.balanceOf(user1), borrow);
    vm.stopPrank();
    
    // change UNI price to 4
    simpleOracle.setUnderlyingPrice(CToken(address(cUNI)), 4 * 1e18);

    vm.startPrank(user2);

    IPool pool = POOL();
    bytes memory data;
    // liquidate half of borrow
    pool.flashLoanSimple(address(this), address(USDC), borrow / 2, data, 0);

    // assert get around 63 USDC
    assertEq(USDC.balanceOf(address(this)) / 10 ** USDC.decimals(), 63);

    vm.stopPrank();
  }

  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external override returns (bool) {
    // approve cUSDC amount
    USDC.approve(address(cUSDC), amount);
    // liquidate user1 borrow USDC and get cUNI back
    CErc20(address(cUSDC)).liquidateBorrow(user1, amount, CErc20(address(cUNI)));
    // redeem cUNI to UNI
    CErc20(address(cUNI)).redeem(CErc20(address(cUNI)).balanceOf(address(this)));
    // approve UNI to swap router
    UNI.approve(ROUTER, UNI.balanceOf(address(this)));

    ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
      tokenIn: address(UNI),
      tokenOut: address(USDC),
      fee: 3000, // 0.3%
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: UNI.balanceOf(address(this)),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0
    });
    // swap UNI to USDC
    ISwapRouter(ROUTER).exactInputSingle(swapParams);
    // approve USDC amount + premium
    USDC.approve(msg.sender, amount + premium);
    return true;
  }

  function ADDRESSES_PROVIDER() public view returns (IPoolAddressesProvider) {
    return IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER);
  }

  function POOL() public view returns (IPool) {
    return IPool(ADDRESSES_PROVIDER().getPool());
  }
}
