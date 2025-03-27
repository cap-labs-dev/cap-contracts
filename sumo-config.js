module.exports = {
  buildDir: 'build',
  contractsDir: 'contracts',
  testDir: 'test',
  skipContracts: [], // Relative paths from contractsDir
  skipTests: [], // Relative paths from testDir
  testingTimeOutInSec: 10,
  network: "none",
  testingFramework: "forge",
  minimal: true,
  tce: true
}