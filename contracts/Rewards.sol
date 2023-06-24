// SPDX-FileCopyrightText: 2023 Stake Together Labs <info@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './StakeTogether.sol';

/// @custom:security-contact security@staketogether.app
contract Rewards is Ownable, Pausable, ReentrancyGuard {
  StakeTogether public stakeTogether;

  event EtherReceived(address indexed sender, uint amount);

  receive() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  fallback() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  event SetStakeTogether(address stakeTogether);

  function setStakeTogether(address _stakeTogether) external onlyOwner {
    require(address(stakeTogether) == address(0), 'STAKE_TOGETHER_ALREADY_SET');
    stakeTogether = StakeTogether(payable(_stakeTogether));
    emit SetStakeTogether(_stakeTogether);
  }

  /*****************
   ** TIME LOCK **
   *****************/

  event ProposeTimeLockAction(string action, uint256 value, address target, uint256 executionTime);
  event ExecuteTimeLockAction(string action);
  event SetTimeLockDuration(uint256 newDuration);
  event SetOraclePenalizeLimit(uint256 newLimit);
  event SetBlockReportGrowthLimit(uint256 newLimit);

  // Todo: add missing events
  // Todo: check if is missing some actions

  struct TimeLockedProposal {
    uint256 value;
    address target;
    uint256 executionTime;
  }

  uint256 public timeLockDuration = 1 days / 15;
  mapping(string => TimeLockedProposal) public timeLockedProposals;

  function proposeTimeLockAction(
    string calldata action,
    uint256 value,
    address target
  ) external onlyOwner {
    TimeLockedProposal storage proposal = timeLockedProposals[action];
    require(proposal.executionTime < block.timestamp, 'Previous proposal still pending.');

    proposal.value = value;
    proposal.target = target;
    proposal.executionTime = block.timestamp + timeLockDuration;

    emit ProposeTimeLockAction(action, value, target, proposal.executionTime);
  }

  function executeTimeLockAction(string calldata action) external onlyOwner {
    TimeLockedProposal storage proposal = timeLockedProposals[action];
    require(block.timestamp >= proposal.executionTime, 'Time lock not expired yet.');

    if (keccak256(bytes(action)) == keccak256(bytes('setTimeLockDuration'))) {
      timeLockDuration = proposal.value;
      emit SetTimeLockDuration(proposal.value);
    } else if (keccak256(bytes(action)) == keccak256(bytes('addOracle'))) {
      _addOracle(proposal.target);
    } else if (keccak256(bytes(action)) == keccak256(bytes('removeOracle'))) {
      _removeOracle(proposal.target);
    } else if (keccak256(bytes(action)) == keccak256(bytes('setOraclePenalizeLimit'))) {
      oraclePenalizeLimit = proposal.value;
      emit SetOraclePenalizeLimit(proposal.value);
    } else if (keccak256(bytes(action)) == keccak256(bytes('setBlockReportLimit'))) {
      reportGrowthLimit = proposal.value;
      emit SetBlockReportGrowthLimit(proposal.value);
    }

    // Todo: Add missing operations

    proposal.executionTime = 0;
    emit ExecuteTimeLockAction(action);
  }

  function isProposalReady(string memory proposalName) public view returns (bool) {
    TimeLockedProposal storage proposal = timeLockedProposals[proposalName];
    return block.timestamp >= proposal.executionTime;
  }

  /*****************
   ** ORACLES **
   *****************/

  modifier onlyOracle() {
    require(
      activeOracles[msg.sender] && oraclesBlacklist[msg.sender] < oraclePenalizeLimit,
      'ONLY_ORACLES'
    );
    _;
  }

  event AddOracle(address oracle);
  event RemoveOracle(address oracle);
  event SetBunkerMode(bool bunkerMode);
  event SetOracleQuorum(uint256 newQuorum);

  event OraclePenalized(
    address indexed oracle,
    uint256 penalties,
    bytes32 penalizedReportHash,
    BlockReport penalizedReport,
    bool removed
  );

  address[] private oracles;
  mapping(address => bool) private activeOracles;
  mapping(address => uint256) public oraclesBlacklist;
  uint256 public oracleQuorum = 1; // Todo: Mainnet = 3
  uint256 public oraclePenalizeLimit = 3;
  bool public bunkerMode = false;

  function getOracles() external view returns (address[] memory) {
    return oracles;
  }

  function getActiveOracleCount() internal view returns (uint256) {
    uint256 activeCount = 0;
    for (uint256 i = 0; i < oracles.length; i++) {
      if (activeOracles[oracles[i]]) {
        activeCount++;
      }
    }
    return activeCount;
  }

  function isOracle(address _oracle) public view returns (bool) {
    return activeOracles[_oracle] && oraclesBlacklist[_oracle] < oraclePenalizeLimit;
  }

  function setBunkerMode(bool _bunkerMode) external onlyOwner {
    bunkerMode = _bunkerMode;
    emit SetBunkerMode(_bunkerMode);
  }

  function _addOracle(address oracle) internal {
    require(!activeOracles[oracle], 'ORACLE_EXISTS');
    oracles.push(oracle);
    activeOracles[oracle] = true;
    emit AddOracle(oracle);
    _updateQuorum();
  }

  function _removeOracle(address oracle) internal {
    require(activeOracles[oracle], 'ORACLE_NOT_EXISTS');
    activeOracles[oracle] = false;
    emit RemoveOracle(oracle);
    _updateQuorum();
  }

  function _updateQuorum() internal onlyOwner {
    uint256 totalOracles = getActiveOracleCount();
    uint256 newQuorum = (totalOracles * 8) / 10;

    newQuorum = newQuorum < 3 ? 3 : newQuorum;
    newQuorum = newQuorum > totalOracles ? totalOracles : newQuorum;

    oracleQuorum = newQuorum;
    emit SetOracleQuorum(newQuorum);
  }

  function _penalizeOracle(address oracle, bytes32 faultyReportHash) internal {
    oraclesBlacklist[oracle]++;

    bool remove = oraclesBlacklist[oracle] >= oraclePenalizeLimit;
    if (remove) {
      _removeOracle(oracle);
    }

    emit OraclePenalized(
      oracle,
      oraclesBlacklist[oracle],
      faultyReportHash,
      blockReports[faultyReportHash],
      remove
    );
  }

  /*****************
   ** BLOCK REPORT **
   *****************/

  modifier onlyAfterBlockConsensus(bytes32 reportHash) {
    require(blockReports[reportHash].meta.consensusExecuted, 'BLOCK_REPORT_CONSENSUS_NOT_EXECUTED');
    _;
  }

  event BlockConsensusApproved(uint256 indexed blockNumber, bytes32 reportHash);
  event BlockConsensusFail(uint256 indexed blockNumber, bytes32 reportHash);

  struct Meta {
    uint256 blockNumber;
    uint256 beaconBalance;
    bool consensusExecuted;
    bytes[] exitedValidators;
  }

  struct Shares {
    uint256 total;
    uint256 stakeTogether;
    uint256 operators;
    uint256 pools;
  }

  struct Amounts {
    uint256 total;
    uint256 stakeTogether;
    uint256 operators;
    uint256 pools;
  }

  struct Pools {
    uint256 total;
    uint256 totalSubmitted;
    uint256 totalSharesSubmitted;
  }

  struct BlockReport {
    Meta meta;
    Shares shares;
    Amounts amounts;
    Pools pools;
  }

  mapping(bytes32 => BlockReport) public blockReports;
  mapping(uint256 => bytes32) public blockConsensusHashByBlock;
  mapping(address => mapping(uint256 => bool)) public oracleBlockReport;
  mapping(bytes32 => uint256) public blockReportsVotes;

  uint256 public reportGrowthLimit = 1;
  uint256 public reportLastBlock = 0;
  uint256 public reportNextBlock = 1;
  uint256 public reportFrequency = 1;

  function submitBlockReport(
    Meta memory _meta,
    Shares memory _shares,
    Amounts memory _amounts,
    Pools memory _pools
  ) external onlyOracle whenNotPaused {
    require(_meta.blockNumber != reportNextBlock, 'INVALID_REPORT_BLOCK_NUMBER');
    require(!oracleBlockReport[msg.sender][_meta.blockNumber], 'ORACLE_ALREADY_REPORTED');
    oracleBlockReport[msg.sender][_meta.blockNumber] = true;

    BlockReport memory blockReport = BlockReport(_meta, _shares, _amounts, _pools);

    bytes32 reportHash = keccak256(abi.encode(_meta, _shares, _amounts, _pools));

    _blockSubmitReportValidator(blockReport, reportHash);

    blockReports[reportHash] = blockReport;
    blockReportsVotes[reportHash]++;

    if (blockReportsVotes[reportHash] >= oracleQuorum) {
      blockConsensusHashByBlock[_meta.blockNumber] = reportHash;
    }
  }

  function executeBlockConsensus(uint256 _blockNumber) external onlyOracle whenNotPaused {
    bytes32 consensusReportHash = blockConsensusHashByBlock[_blockNumber];
    require(consensusReportHash != bytes32(0), 'INVALID_CONSENSUS_HASH');

    uint256 votes = blockReportsVotes[consensusReportHash];
    BlockReport storage consensusReport = blockReports[consensusReportHash];

    _blockExecuteReportValidator(consensusReport);

    bool isConsensusApproved = consensusReport.shares.pools ==
      consensusReport.pools.totalSharesSubmitted &&
      consensusReport.pools.total == consensusReport.pools.totalSubmitted;

    if (votes >= oracleQuorum && isConsensusApproved) {
      consensusReport.meta.consensusExecuted = true;
      _blockReportActions(consensusReport);
      emit BlockConsensusApproved(_blockNumber, consensusReportHash);
    }

    reportLastBlock = reportNextBlock;
    reportNextBlock += reportFrequency;
    emit BlockConsensusFail(_blockNumber, consensusReportHash);
  }

  function isBlockReportReady(uint256 blockNumber) public view returns (bool) {
    bytes32 reportHash = blockConsensusHashByBlock[blockNumber];
    return blockReportsVotes[reportHash] >= oracleQuorum;
  }

  function _blockSubmitReportValidator(
    BlockReport memory _blockReport,
    bytes32 _reportHash
  ) private view {
    // Todo: Check if is missing some validation
    require(_blockReport.meta.blockNumber == reportNextBlock, 'BLOCK_REPORT_IS_NOT_NEXT_EXPECTED');
    require(_blockReport.meta.consensusExecuted == false, 'INVALID_CONSENSUS_EXECUTED');
    require(_blockReport.pools.totalSharesSubmitted == 0, 'INVALID_TOTAL_POOLS_SHARES_SUBMITTED');
    require(_blockReport.pools.totalSubmitted == 0, 'INVALID_TOTAL_POOLS_SUBMITTED');

    uint256 totalPooledEther = stakeTogether.totalPooledEther();
    uint256 growthLimit = Math.mulDiv(totalPooledEther, reportGrowthLimit, 100);
    require(_blockReport.amounts.total <= growthLimit, 'GROWTH_LIMIT_EXCEEDED');

    uint256 stakeTogetherFee = Math.mulDiv(totalPooledEther, stakeTogether.stakeTogetherFee(), 100);
    uint256 operatorFee = Math.mulDiv(totalPooledEther, stakeTogether.operatorFee(), 100);
    uint256 poolFee = Math.mulDiv(totalPooledEther, stakeTogether.poolFee(), 100);
    require(
      stakeTogether.pooledEthByShares(_blockReport.shares.stakeTogether) <= stakeTogetherFee,
      'STAKE_TOGETHER_FEE_EXCEEDED'
    );
    require(
      stakeTogether.pooledEthByShares(_blockReport.shares.operators) <= operatorFee,
      'OPERATOR_FEE_EXCEEDED'
    );
    require(stakeTogether.pooledEthByShares(_blockReport.shares.pools) <= poolFee, 'POOL_FEE_EXCEEDED');

    uint256 totalShares = _blockReport.shares.stakeTogether +
      _blockReport.shares.operators +
      _blockReport.shares.pools;
    require(totalShares == _blockReport.shares.total, 'INVALID_TOTAL_SHARES');

    for (uint i = 0; i < _blockReport.meta.exitedValidators.length; i++) {
      require(
        stakeTogether.isValidator(_blockReport.meta.exitedValidators[i]),
        'INVALID_EXITED_VALIDATOR'
      );
    }

    uint256 expectedMaxBeaconBalance = stakeTogether.validatorSize() * stakeTogether.totalValidators();
    require(
      _blockReport.meta.beaconBalance <= expectedMaxBeaconBalance,
      'BEACON_BALANCE_EXCEEDS_EXPECTED_MAX'
    );

    require(!blockReports[_reportHash].meta.consensusExecuted, 'BLOCK_ALREADY_EXECUTED');
  }

  function _blockExecuteReportValidator(BlockReport storage consensusReport) private view {
    require(!consensusReport.meta.consensusExecuted, 'REPORT_ALREADY_EXECUTED');

    require(
      consensusReport.pools.total == consensusReport.pools.totalSubmitted,
      'INVALID_POOLS_SUBMISSION'
    );

    require(
      consensusReport.shares.pools == consensusReport.pools.totalSharesSubmitted,
      'INVALID_POOLS_SHARES_SUBMISSION'
    );
  }

  function _blockReportActions(BlockReport memory _blockReport) private {
    stakeTogether.setBeaconBalance(_blockReport.meta.blockNumber, _blockReport.meta.beaconBalance);

    stakeTogether.mintRewards{ value: _blockReport.amounts.stakeTogether }(
      _blockReport.meta.blockNumber,
      stakeTogether.stakeTogetherFeeAddress(),
      _blockReport.shares.stakeTogether
    );

    stakeTogether.mintRewards{ value: _blockReport.amounts.operators }(
      _blockReport.meta.blockNumber,
      stakeTogether.operatorFeeAddress(),
      _blockReport.shares.operators
    );

    stakeTogether.removeValidators(_blockReport.meta.exitedValidators);

    // Todo: Implement Actions
    // stakeTogether.setBeaconBalance(_blockReport.beaconBalance);
    // stakeTogether mintSharesRewards (public function only for oracle)
    // transfer ethereum to stake together (pooledEtherByShares)

    // Todo: Missing

    // uint256 poolShares;
    // uint256 poolsToSubmit;
    // uint256 poolsSubmitted;
    // uint256 poolsSharesSubmitted;
    // bool consensusExecuted;

    // Todo: Consensus will be executed just when last pool submits the report
  }

  /*****************
   ** POOL REPORT **
   *****************/

  event PoolConsensusApproved(uint256 indexed blockNumber, bytes32 reportHash);
  event PoolConsensusFail(uint256 indexed blockNumber, bytes32 reportHash);

  struct PoolReport {
    address pool;
    address sharesAmount;
    bytes32 reportHash;
    bool consensusExecuted;
  }

  mapping(bytes32 => PoolReport) public poolReports;
  mapping(bytes32 => PoolReport[]) public poolReportsByBlock;

  // function submitPoolReport(
  //   bytes32 reportHash,
  //   address[] calldata pools,
  //   uint256[] calldata sharesAmounts
  // ) external onlyAfterBlockConsensus(reportHash) onlyOracle whenNotPaused {
  //   require(reports[reportHash].blockNumber != 0, 'Report not submitted yet');
  //   require(pools.length == sharesAmounts.length, 'Mismatch in array lengths');

  //   bytes32 poolReportHash = keccak256(abi.encode(reportHash, pools, sharesAmounts));

  //   for (uint256 i = 0; i < sharesAmounts.length; i++) {
  //     reports[reportHash].poolSharesSubmitted += sharesAmounts[i];
  //   }

  //   poolReports[poolReportHash] = PoolReport(pools, sharesAmounts, reportHash);
  //   poolReportsByReportHash[reportHash].push(poolReportHash);
  // }

  // function executePoolConsensus(
  //   bytes32 reportHash,
  //   uint256 blockNumber,
  //   uint256 pageNumber
  // ) external onlyAfterBlockConsensus(reportHash) onlyOracle whenNotPaused {
  //   bytes32[] storage poolBlockReports = poolReportsByBlock[blockNumber];
  //   uint256 maxVotes = 0;
  //   bytes32 consensusReportHash;

  //   // Similar loop to find consensus report hash

  //   // If we got more votes than the oracleQuorum,
  //   // we consider it a valid report and update the state
  //   if (maxVotes >= oracleQuorum) {
  //     // Check if consensus was already executed for this pool report
  //     require(!consensusPoolReport.consensusExecuted, 'Consensus already executed for this pool report');

  //     consensusPoolReport.consensusExecuted = true;
  //     PoolReport memory consensusPoolReport = poolReports[consensusReportHash];

  //     uint256 pageSize = 100; // Define your preferred page size here
  //     uint256 startIndex = pageNumber * pageSize;
  //     require(startIndex < consensusPoolReport.pools.length, 'Page number out of range');

  //     uint256 endIndex = startIndex + pageSize > consensusPoolReport.pools.length
  //       ? consensusPoolReport.pools.length
  //       : startIndex + pageSize;

  //     uint256 totalShares = 0;
  //     for (uint256 i = startIndex; i < endIndex; i++) {
  //       totalShares += consensusPoolReport.sharesAmounts[i];
  //       // Process the pool shares here based on consensusPoolReport.sharesAmounts[i]
  //     }

  //     bytes32 generalReportHash = consensusReportHashByBlock[blockNumber];
  //     Report memory generalReport = reports[generalReportHash];

  //     require(totalShares <= generalReport.poolShares, 'Mismatch in poolShares total');

  //     if (endIndex == consensusPoolReport.pools.length) {
  //       // We've processed the last page
  //       emit PoolConsensusApproved(blockNumber, consensusReportHash);
  //     }
  //   } else {
  //     emit PoolConsensusFail(blockNumber, consensusReportHash);
  //   }
  // }
}
