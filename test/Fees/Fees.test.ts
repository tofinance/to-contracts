import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { expect } from 'chai'
import dotenv from 'dotenv'
import { ethers, upgrades } from 'hardhat'
import { Fees, FeesV2__factory } from '../../typechain'
import connect from '../utils/connect'
import { feesFixture } from './FeesFixture'

dotenv.config()

describe('Fees', function () {
  let feesContract: Fees
  let feesProxy: string
  let owner: HardhatEthersSigner
  let user1: HardhatEthersSigner
  let user2: HardhatEthersSigner
  let ADMIN_ROLE: string

  // Setting up the fixture before each test
  beforeEach(async function () {
    const fixture = await loadFixture(feesFixture)
    feesContract = fixture.feesContract
    feesProxy = fixture.feesProxy
    owner = fixture.owner
    user1 = fixture.user1
    user2 = fixture.user2
    ADMIN_ROLE = fixture.ADMIN_ROLE
  })

  // Test to check if pause and unpause functions work properly
  it('should pause and unpause the contract if the user has admin role', async function () {
    // Check if the contract is not paused at the beginning
    expect(await feesContract.paused()).to.equal(false)

    // User without admin role tries to pause the contract - should fail
    await expect(connect(feesContract, user1).pause()).to.reverted

    // The owner pauses the contract
    await connect(feesContract, owner).pause()

    // Check if the contract is paused
    expect(await feesContract.paused()).to.equal(true)

    // User without admin role tries to unpause the contract - should fail
    await expect(connect(feesContract, user1).unpause()).to.reverted

    // The owner unpauses the contract
    await connect(feesContract, owner).unpause()
    // Check if the contract is not paused
    expect(await feesContract.paused()).to.equal(false)
  })

  it('should upgrade the contract if the user has upgrader role', async function () {
    expect(await feesContract.version()).to.equal(1n)

    const FeesV2Factory = new FeesV2__factory(user1)

    // A user without the UPGRADER_ROLE tries to upgrade the contract - should fail
    await expect(upgrades.upgradeProxy(feesProxy, FeesV2Factory)).to.be.reverted

    const FeesV2FactoryOwner = new FeesV2__factory(owner)

    // The owner (who has the UPGRADER_ROLE) upgrades the contract - should succeed
    const upgradedFeesContract = await upgrades.upgradeProxy(feesProxy, FeesV2FactoryOwner)

    // Upgrade version
    await upgradedFeesContract.initializeV2()

    expect(await upgradedFeesContract.version()).to.equal(2n)
  })

  it('should correctly set the StakeTogether address', async function () {
    // User1 tries to set the StakeTogether address - should fail
    await expect(connect(feesContract, user1).setStakeTogether(user1.address)).to.be.reverted

    // Owner sets the StakeTogether address - should succeed
    await connect(feesContract, owner).setStakeTogether(user1.address)

    // Verify that the StakeTogether address was correctly set
    expect(await feesContract.stakeTogether()).to.equal(user1.address)
  })

  it('should correctly receive Ether and transfer to StakeTogether via receive', async function () {
    // Set the StakeTogether address to user1
    await connect(feesContract, owner).setStakeTogether(user1.address)

    const initBalance = await ethers.provider.getBalance(user1.address)

    // User2 sends 1 Ether to the contract's receive function
    const tx = await user2.sendTransaction({
      to: feesProxy,
      value: ethers.parseEther('1.0')
    })

    // Simulate confirmation of the transaction
    await tx.wait()

    // Verify that the Ether was correctly transferred to user1 (StakeTogether)
    const finalBalance = await ethers.provider.getBalance(user1.address)
    expect(finalBalance).to.equal(initBalance + ethers.parseEther('1.0'))

    // Verify that the ReceiveEther event was emitted
    await expect(tx)
      .to.emit(feesContract, 'ReceiveEther')
      .withArgs(user2.address, ethers.parseEther('1.0'))
  })
})
