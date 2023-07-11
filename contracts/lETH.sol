// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import './StakeTogether.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './Pool.sol';
import './Distributor.sol';

contract LETH is AccessControl, Pausable, ReentrancyGuard, ERC20, ERC20Burnable, ERC20Permit {
  bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');
  bytes32 public constant ORACLE_REPORT_ROLE = keccak256('ORACLE_REPORT_ROLE');
  bytes32 public constant ORACLE_REWARDS_ROLE = keccak256('ORACLE_REWARDS_ROLE');

  StakeTogether public stakeTogether;
  Distributor public distributor;

  /***********************
   ** LIQUIDITY **
   ***********************/

  event EtherReceived(address indexed sender, uint amount);
  event SetStakeTogether(address stakeTogether);
  event SetLiquidityFee(uint256 fee);
  event SetStakeTogetherLiquidityFee(uint256 fee);
  event SetPoolLiquidityFee(uint256 fee);
  event AddLiquidity(address indexed user, uint256 amount);
  event RemoveLiquidity(address indexed user, uint256 amount);
  event Borrow(address indexed user, uint256 amount);
  event RepayLoan(address indexed user, uint256 amount);
  event ReDeposit(address indexed user, uint256 amount);
  event ReDepositBatch(address indexed user, uint256[] amounts);
  event SetEnableBorrow(bool enable);

  uint256 public liquidityFee = 0.01 ether;
  uint256 public stakeTogetherLiquidityFee = 0.15 ether;
  uint256 public poolLiquidityFee = 0.15 ether;
  bool public enableBorrow = true;

  constructor(
    address _distributorContract
  ) ERC20('ST Lending Ether', 'LETH') ERC20Permit('ST Lending Ether') {
    distributor = Distributor(payable(_distributorContract));
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(ADMIN_ROLE, msg.sender);
  }

  receive() external payable {
    _checkExtraAmount();
    emit EtherReceived(msg.sender, msg.value);
  }

  modifier onlyStakeTogether() {
    require(msg.sender == address(stakeTogether), 'ONLY_STAKE_TOGETHER_CONTRACT');
    _;
  }

  function mint(address _to, uint256 _amount) internal whenNotPaused {
    _mint(_to, _amount);
  }

  function setStakeTogether(address _stakeTogether) external onlyRole(ADMIN_ROLE) {
    require(_stakeTogether != address(0), 'STAKE_TOGETHER_ALREADY_SET');
    stakeTogether = StakeTogether(payable(_stakeTogether));
    emit SetStakeTogether(_stakeTogether);
  }

  function setLiquidityFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    require(_fee > 0, 'ZERO_FEE');
    liquidityFee = _fee;
    emit SetLiquidityFee(_fee);
  }

  function setStakeTogetherLiquidityFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    require(_fee > 0, 'ZERO_FEE');
    stakeTogetherLiquidityFee = _fee;
    emit SetStakeTogetherLiquidityFee(_fee);
  }

  function setPoolLiquidityFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    require(_fee > 0, 'ZERO_FEE');
    stakeTogetherLiquidityFee = _fee;
    emit SetPoolLiquidityFee(_fee);
  }

  function setEnableBorrow(bool _enable) external onlyRole(ADMIN_ROLE) {
    enableBorrow = _enable;
    emit SetEnableBorrow(_enable);
  }

  function addLiquidity() public payable whenNotPaused nonReentrant {
    _mint(msg.sender, msg.value);
    emit AddLiquidity(msg.sender, msg.value);
  }

  function removeLiquidity(uint256 _amount) public whenNotPaused nonReentrant {
    require(_amount > 0, 'ZERO_AMOUNT');
    require(balanceOf(msg.sender) >= _amount, 'INSUFFICIENT_LETH_BALANCE');
    require(address(this).balance >= _amount, 'INSUFFICIENT_ETH_BALANCE');

    _burn(msg.sender, _amount);
    payable(msg.sender).transfer(_amount);
    emit RemoveLiquidity(msg.sender, _amount);
  }

  function borrow(uint256 _amount, address _pool) public whenNotPaused nonReentrant onlyStakeTogether {
    require(enableBorrow, 'BORROW_DISABLED');
    require(_amount > 0, 'ZERO_AMOUNT');
    require(address(this).balance >= _amount, 'INSUFFICIENT_ETH_BALANCE');

    uint256 total = _amount + Math.mulDiv(_amount, liquidityFee, 1 ether);

    uint256 stakeTogetherShare = Math.mulDiv(total, stakeTogetherLiquidityFee, 1 ether);
    uint256 poolShare = Math.mulDiv(total, poolLiquidityFee, 1 ether);

    uint256 liquidityProviderShare = total - stakeTogetherShare - poolShare;

    _mint(stakeTogether.stakeTogetherFeeAddress(), stakeTogetherShare);
    _mint(_pool, poolShare);
    _mint(msg.sender, liquidityProviderShare);

    emit Borrow(msg.sender, _amount);
  }

  function repayLoan() public payable whenNotPaused nonReentrant onlyStakeTogether {
    require(msg.value > 0, 'ZERO_AMOUNT');
    require(balanceOf(msg.sender) >= msg.value, 'INSUFFICIENT_LETH_BALANCE');

    _burn(msg.sender, msg.value);
    emit RepayLoan(msg.sender, msg.value);
  }

  function _checkExtraAmount() internal {
    uint256 totalSupply = totalSupply();
    if (address(this).balance > totalSupply) {
      uint256 extraAmount = address(this).balance - totalSupply;
      _transferToStakeTogether(extraAmount);
    }
  }

  function _transferToStakeTogether(uint256 _amount) private {
    payable(address(stakeTogether)).transfer(_amount);
  }

  /***********************
   ** ANTICIPATION **
   ***********************/

  modifier onlyDistributor() {
    require(msg.sender == address(distributor), 'ONLY_DISTRIBUTOR_CONTRACT');
    _;
  }

  event SetApr(uint256 epoch, uint256 apr);
  event SetMaxAnticipateFraction(uint256 fraction);
  event SetMaxAnticipationDays(uint256 anticipationDays);
  event SetAnticipationFeeRange(uint256 minFee, uint256 maxFee);
  event SetStakeTogetherAnticipateFee(uint256 fee);
  event SetPoolAnticipateFee(uint256 fee);
  event AnticipateRewards(
    address indexed user,
    uint256 anticipatedAmount,
    uint256 netAmount,
    uint256 fee
  );
  event SetEnableAnticipation(bool enable);

  uint256 public apr = 0.05 ether;
  uint256 public maxAnticipateFraction = 0.5 ether;
  uint256 public maxAnticipationDays = 365;
  uint256 public minAnticipationFee = 0.01 ether;
  uint256 public maxAnticipationFee = 1 ether;

  uint256 public stakeTogetherAnticipateFee = 0.15 ether;
  uint256 public poolAnticipateFee = 0.15 ether;
  bool public enableAnticipation = true;

  function setApr(uint256 _epoch, uint256 _apr) external onlyDistributor {
    apr = _apr;
    emit SetApr(_epoch, _apr);
  }

  function setMaxAnticipateFraction(uint256 _fraction) external onlyRole(ADMIN_ROLE) {
    maxAnticipateFraction = _fraction;
    emit SetMaxAnticipateFraction(_fraction);
  }

  function setMaxAnticipationDays(uint256 _days) external onlyRole(ADMIN_ROLE) {
    maxAnticipationDays = _days;
    emit SetMaxAnticipationDays(_days);
  }

  function setAnticipationFeeRange(uint256 _minFee, uint256 _maxFee) external onlyRole(ADMIN_ROLE) {
    minAnticipationFee = _minFee;
    maxAnticipationFee = _maxFee;
    emit SetAnticipationFeeRange(_minFee, _maxFee);
  }

  function setStakeTogetherAnticipateFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    require(_fee > 0, 'ZERO_FEE');
    stakeTogetherAnticipateFee = _fee;
    emit SetStakeTogetherAnticipateFee(_fee);
  }

  function setPoolAnticipateFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    require(_fee > 0, 'ZERO_FEE');
    stakeTogetherAnticipateFee = _fee;
    emit SetPoolAnticipateFee(_fee);
  }

  function setEnableAnticipation(bool _enable) external onlyRole(ADMIN_ROLE) {
    enableAnticipation = _enable;
    emit SetEnableAnticipation(_enable);
  }

  function estimateMaxAnticipation(uint256 _amount, uint256 _days) public view returns (uint256) {
    require(_days <= maxAnticipationDays, 'EXCEEDS_MAX_DAYS');

    uint256 totalApr = Math.mulDiv(_amount, apr, 1 ether);
    uint256 dailyApr = Math.mulDiv(totalApr, _days, maxAnticipationDays);

    uint256 maxAnticipate = Math.mulDiv(dailyApr, maxAnticipateFraction, 1 ether);

    return maxAnticipate;
  }

  function estimateAnticipationFee(uint256 _amount, uint256 _days) public view returns (uint256) {
    require(_days <= maxAnticipationDays, 'EXCEEDS_MAX_DAYS');

    uint256 maxAnticipate = estimateMaxAnticipation(_amount, _days);

    uint256 feeReduction = Math.mulDiv(
      maxAnticipationFee - minAnticipationFee,
      _days,
      maxAnticipationDays
    );
    uint256 fee = Math.mulDiv(maxAnticipate, maxAnticipationFee - feeReduction, 1 ether);

    return fee;
  }

  function estimateNetAnticipatedAmount(uint256 _amount, uint256 _days) public view returns (uint256) {
    require(_days <= maxAnticipationDays, 'EXCEEDS_MAX_DAYS');

    uint256 maxAnticipate = estimateMaxAnticipation(_amount, _days);
    uint256 fee = estimateAnticipationFee(_amount, _days);

    uint256 netAmount = maxAnticipate - fee;

    return netAmount;
  }

  function anticipateRewards(uint256 _amount, address _pool, uint256 _days) external nonReentrant {
    require(enableAnticipation, 'ANTICIPATION_DISABLED');
    require(_amount > 0, 'ZERO_AMOUNT');
    require(_days > 0, 'ZERO_DAYS');
    require(_days <= maxAnticipationDays, 'EXCEEDS_MAX_DAYS');

    uint256 accountBalance = stakeTogether.balanceOf(msg.sender);
    require(accountBalance > 0, 'ZERO_ST_BALANCE');

    uint256 maxAnticipate = estimateMaxAnticipation(accountBalance, _days);
    require(_amount <= maxAnticipate, 'AMOUNT_EXCEEDS_MAX_ANTICIPATE');

    uint256 fee = estimateAnticipationFee(_amount, _days);
    require(fee < _amount, 'FEE_EXCEEDS_AMOUNT');

    uint256 stakeTogetherShare = Math.mulDiv(fee, stakeTogetherAnticipateFee, 1 ether);
    uint256 poolShare = Math.mulDiv(fee, poolAnticipateFee, 1 ether);
    uint256 usersShare = fee - stakeTogetherShare - poolShare;

    uint256 netAmount = _amount - fee;
    require(netAmount > 0, 'NET_AMOUNT_ZERO_OR_NEGATIVE');

    require(address(this).balance >= netAmount, 'INSUFFICIENT_CONTRACT_BALANCE');

    uint256 sharesToLock = stakeTogether.sharesByPooledEth(_amount);

    // Todo: check twice money

    uint256 blocks = (_days * 24 * 60 * 60) / 12; // Eth Block Time = 12

    stakeTogether.lockShares(sharesToLock, blocks);

    payable(msg.sender).transfer(netAmount);

    _mint(stakeTogether.stakeTogetherFeeAddress(), stakeTogetherShare);
    _mint(_pool, poolShare);
    _mint(msg.sender, usersShare);

    emit AnticipateRewards(msg.sender, _amount, netAmount, fee);
  }

  // Todo: devolute antecipated rewards

  /***********************
   ** REDEPOSIT **
   ***********************/

  event SetMaxBatchSize(uint256 size);

  uint256 public maxBatchSize = 100;

  function setMaxBatchSize(uint256 _size) external onlyRole(ADMIN_ROLE) {
    require(_size > 0, 'ZERO_SIZE');
    maxBatchSize = _size;
    emit SetMaxBatchSize(_size);
  }

  function reDeposit(
    uint256 _amount,
    address _pool,
    address _referral
  ) public whenNotPaused nonReentrant onlyRole(ORACLE_REWARDS_ROLE) {
    require(_amount > 0, 'ZERO_AMOUNT');
    require(balanceOf(msg.sender) >= _amount, 'INSUFFICIENT_LETH_BALANCE');
    require(address(this).balance >= _amount, 'INSUFFICIENT_ETH_BALANCE');

    _burn(msg.sender, _amount);
    stakeTogether.depositPool{ value: _amount }(_pool, _referral);
    emit ReDeposit(msg.sender, _amount);
  }

  function reDepositBatch(
    uint256[] memory _amounts,
    address[] memory _pools,
    address[] memory _referrals
  ) public whenNotPaused nonReentrant onlyRole(ORACLE_REWARDS_ROLE) {
    require(_amounts.length <= maxBatchSize, 'BATCH_SIZE_TOO_LARGE');
    require(_amounts.length == _pools.length, 'ARRAY_LENGTH_MISMATCH');
    require(_pools.length == _referrals.length, 'ARRAY_LENGTH_MISMATCH');

    for (uint i = 0; i < _amounts.length; i++) {
      require(_amounts[i] > 0, 'ZERO_AMOUNT');
      require(balanceOf(msg.sender) >= _amounts[i], 'INSUFFICIENT_LETH_BALANCE');
      require(address(this).balance >= _amounts[i], 'INSUFFICIENT_ETH_BALANCE');

      _burn(msg.sender, _amounts[i]);
      stakeTogether.depositPool{ value: _amounts[i] }(_pools[i], _referrals[i]);
    }

    emit ReDepositBatch(msg.sender, _amounts);
  }
}
