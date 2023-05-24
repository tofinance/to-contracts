// SPDX-FileCopyrightText: 2023 Stake Together <info@staketogether.app>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import './CETH.sol';
import './STOracle.sol';
import './STValidator.sol';

contract StakeTogether is CETH {
  STOracle public immutable stOracle;
  STValidator public immutable stValidator;

  constructor(address _stOracle, address _stValidator) payable {
    stOracle = STOracle(_stOracle);
    stValidator = STValidator(_stValidator);
  }

  /*****************
   ** STAKE **
   *****************/

  event Deposit(
    address indexed account,
    uint256 amount,
    uint256 shares,
    address delegated,
    address referral
  );
  event Withdraw(address indexed account, uint256 amount, uint256 shares, address delegated);

  uint256 public immutable poolSize = 32 ether;
  uint256 public minAmount = 0.000000000000000001 ether;

  function deposit(address _delegated, address _referral) external payable nonReentrant whenNotPaused {
    require(_isCommunity(_delegated), 'NON_COMMUNITY_DELEGATE');
    require(msg.value > 0, 'ZERO_VALUE');
    require(msg.value >= minAmount, 'NON_MIN_AMOUNT');

    uint256 sharesAmount = (msg.value * totalShares) / (getTotalPooledEther() - msg.value);

    _mintShares(msg.sender, sharesAmount);
    _mintDelegatedShares(msg.sender, _delegated, sharesAmount);

    emit Deposit(msg.sender, msg.value, sharesAmount, _delegated, _referral);
  }

  function withdraw(uint256 _amount, address _delegated) external nonReentrant whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(_delegated != address(0), 'MINT_TO_ZERO_ADDR');
    require(_amount <= getWithdrawalsBalance(), 'NOT_ENOUGH_CONTRACT_BALANCE');
    require(delegationSharesOf(msg.sender, _delegated) > 0, 'NOT_DELEGATION_SHARES');

    uint256 userBalance = balanceOf(msg.sender);

    require(_amount <= userBalance, 'AMOUNT_EXCEEDS_BALANCE');

    uint256 sharesToBurn = (_amount * sharesOf(msg.sender)) / userBalance;

    _burnShares(msg.sender, sharesToBurn);
    _burnDelegatedShares(msg.sender, _delegated, sharesToBurn);

    emit Withdraw(msg.sender, _amount, sharesToBurn, _delegated);

    payable(msg.sender).transfer(_amount);
  }

  function setMinimumStakeAmount(uint256 _amount) external onlyOwner {
    minAmount = _amount;
  }

  function getPoolBalance() public view returns (uint256) {
    return address(this).balance - withdrawalsBuffer;
  }

  function getTotalPooledEther() public view override returns (uint256) {
    // Todo: Implement Transient Balance
    return (clBalance + address(this).balance) - withdrawalsBuffer;
  }

  function getTotalEtherSupply() public view returns (uint256) {
    return clBalance + address(this).balance + withdrawalsBuffer;
  }

  /*****************
   ** WITHDRAWALS **
   *****************/

  event DepositBuffer(address indexed account, uint256 amount);
  event WithdrawBuffer(address indexed account, uint256 amount);

  uint256 public withdrawalsBuffer = 0;

  function depositBuffer() external payable onlyOwner nonReentrant whenNotPaused {
    require(msg.value > 0, 'ZERO_VALUE');
    withdrawalsBuffer += msg.value;

    emit DepositBuffer(msg.sender, msg.value);
  }

  function withdrawBuffer(uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(withdrawalsBuffer > _amount, 'AMOUNT_EXCEEDS_BUFFER');

    withdrawalsBuffer -= _amount;

    payable(owner()).transfer(_amount);

    emit WithdrawBuffer(msg.sender, _amount);
  }

  function getWithdrawalsBalance() public view returns (uint256) {
    return address(this).balance + withdrawalsBuffer;
  }

  /*****************
   ** REWARDS **
   *****************/

  event ConsensusLayerBalanceUpdated(uint256 _balance);

  function setClBalance(uint256 _balance) external override nonReentrant {
    require(msg.sender == address(stOracle), 'ONLY_ST_ORACLE');

    uint256 preClBalance = clBalance;
    clBalance = _balance;

    _processRewards(preClBalance, clBalance);

    emit ConsensusLayerBalanceUpdated(clBalance);
  }

  /*****************
   ** VALIDATOR **
   *****************/

  function createValidator(
    bytes calldata _publicKey,
    bytes calldata _signature,
    bytes32 _depositDataRoot
  ) external onlyOwner nonReentrant {
    require(getPoolBalance() >= poolSize, 'NOT_ENOUGH_POOL_BALANCE');
    stValidator.createValidator{ value: poolSize }(_publicKey, _signature, _depositDataRoot);
  }
}
