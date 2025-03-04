// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Combine
import XCTest
import BraveCore
@testable import BraveWallet

class AccountActivityStoreTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = .init()

  let networks: [BraveWallet.CoinType: [BraveWallet.NetworkInfo]] = [
    .eth: [.mockMainnet, .mockGoerli],
    .sol: [.mockSolana, .mockSolanaTestnet]
  ]
  let tokenRegistry: [BraveWallet.CoinType: [BraveWallet.BlockchainToken]] = [:]
  let mockAssetPrices: [BraveWallet.AssetPrice] = [
    .init(fromAsset: "eth", toAsset: "usd", price: "3059.99", assetTimeframeChange: "-57.23"),
    .init(fromAsset: BraveWallet.BlockchainToken.mockUSDCToken.assetRatioId,
          toAsset: "usd", price: "1.00", assetTimeframeChange: "-57.23"),
    .init(fromAsset: "sol", toAsset: "usd", price: "2.00", assetTimeframeChange: "-57.23"),
    .init(fromAsset: BraveWallet.BlockchainToken.mockSpdToken.assetRatioId.lowercased(),
          toAsset: "usd", price: "0.50", assetTimeframeChange: "-57.23")
  ]

  private func setupServices(
    mockEthBalanceWei: String = "",
    mockERC20BalanceWei: String = "",
    mockERC721BalanceWei: String = "",
    mockLamportBalance: UInt64 = 0,
    mockSplTokenBalances: [String: String] = [:], // [tokenMintAddress: balance]
    transactions: [BraveWallet.TransactionInfo]
  ) -> (BraveWallet.TestKeyringService, BraveWallet.TestJsonRpcService, BraveWallet.TestBraveWalletService, BraveWallet.TestBlockchainRegistry, BraveWallet.TestAssetRatioService, BraveWallet.TestTxService, BraveWallet.TestSolanaTxManagerProxy, IpfsAPI) {
    let keyringService = BraveWallet.TestKeyringService()
    keyringService._addObserver = { _ in }
    keyringService._keyringInfo = { _, completion in
      completion(.mockDefaultKeyringInfo)
    }

    let rpcService = BraveWallet.TestJsonRpcService()
    rpcService._addObserver = { _ in }
    rpcService._allNetworks = { coin, completion in
      completion(self.networks[coin] ?? [])
    }
    rpcService._balance = { _, _, _, completion in
      completion(mockEthBalanceWei, .success, "") // eth balance
    }
    rpcService._erc20TokenBalance = { _, _, _, completion in
      completion(mockERC20BalanceWei, .success, "")
    }
    rpcService._erc721TokenBalance = { _, _, _, _, completion in
      completion(mockERC721BalanceWei, .success, "") // eth nft balance
    }
    rpcService._solanaBalance = { accountAddress, chainId, completion in
      completion(mockLamportBalance, .success, "") // sol balance
    }
    rpcService._splTokenAccountBalance = { _, tokenMintAddress, _, completion in
      // spd token, sol nft balance
      completion(mockSplTokenBalances[tokenMintAddress] ?? "", UInt8(0), mockSplTokenBalances[tokenMintAddress] ?? "", .success, "")
    }
    rpcService._erc721Metadata = { _, _, _, completion in
      let metadata = """
      {
        "image": "mock.image.url",
        "name": "mock nft name",
        "description": "mock nft description"
      }
      """
      completion( "", metadata, .success, "")
    }
    rpcService._solTokenMetadata = { _, _, completion in
      let metaData = """
      {
        "image": "sol.mock.image.url",
        "name": "sol mock nft name",
        "description": "sol mock nft description"
      }
      """
      completion("", metaData, .success, "")
    }
    
    let walletService = BraveWallet.TestBraveWalletService()
    walletService._addObserver = { _ in }
    walletService._defaultBaseCurrency = { $0(CurrencyCode.usd.code) }

    let blockchainRegistry = BraveWallet.TestBlockchainRegistry()
    blockchainRegistry._allTokens = { chainId, coin, completion in
      completion(self.tokenRegistry[coin] ?? [])
    }

    let assetRatioService = BraveWallet.TestAssetRatioService()
    assetRatioService._price = { _, _, _, completion in
      completion(true, self.mockAssetPrices)
    }
    
    let txService = BraveWallet.TestTxService()
    txService._addObserver = { _ in }
    txService._allTransactionInfo = { coin, chainId, _, completion in
      completion(transactions.filter({ $0.chainId == chainId }))
    }
    
    let solTxManagerProxy = BraveWallet.TestSolanaTxManagerProxy()
    solTxManagerProxy._estimatedTxFee = { $2(0, .success, "") }
    
    let ipfsApi = TestIpfsAPI()

    return (keyringService, rpcService, walletService, blockchainRegistry, assetRatioService, txService, solTxManagerProxy, ipfsApi)
  }
  
  func testUpdateEthereumAccount() {
    let firstTransactionDate = Date(timeIntervalSince1970: 1636399671) // Monday, November 8, 2021 7:27:51 PM
    let account: BraveWallet.AccountInfo = .mockEthAccount
    let formatter = WeiFormatter(decimalFormatStyle: .decimals(precision: 18))
    let mockEthDecimalBalance: Double = 0.0896
    let numEthDecimals = Int(BraveWallet.NetworkInfo.mockMainnet.nativeToken.decimals)
    let mockEthBalanceWei = formatter.weiString(from: mockEthDecimalBalance, radix: .hex, decimals: numEthDecimals) ?? ""
    let mockERC20DecimalBalance = 1.5
    let mockERC20BalanceWei = formatter.weiString(from: mockERC20DecimalBalance, radix: .hex, decimals: Int(BraveWallet.BlockchainToken.mockUSDCToken.decimals)) ?? ""
    let mockNFTBalance: Double = 1
    let mockERC721BalanceWei = formatter.weiString(from: mockNFTBalance, radix: .hex, decimals: 0) ?? ""
    
    let mockERC721Metadata: NFTMetadata = .init(imageURLString: "mock.image.url", name: "mock nft name", description: "mock nft description")
    
    let ethSendTxCopy = BraveWallet.TransactionInfo.previewConfirmedSend.copy() as! BraveWallet.TransactionInfo // default in mainnet
    let goerliSwapTxCopy = BraveWallet.TransactionInfo.previewConfirmedSwap.copy() as! BraveWallet.TransactionInfo
    goerliSwapTxCopy.chainId = BraveWallet.GoerliChainId
    
    let (keyringService, rpcService, walletService, blockchainRegistry, assetRatioService, txService, solTxManagerProxy, ipfsApi) = setupServices(
      mockEthBalanceWei: mockEthBalanceWei,
      mockERC20BalanceWei: mockERC20BalanceWei,
      mockERC721BalanceWei: mockERC721BalanceWei,
      transactions: [goerliSwapTxCopy, ethSendTxCopy].enumerated().map { (index, tx) in
        // transactions sorted by created time, make sure they are in-order
        tx.createdTime = firstTransactionDate.addingTimeInterval(TimeInterval(index * 10))
        return tx
      }
    )
    
    let mockAssetManager = TestableWalletUserAssetManager()
    mockAssetManager._getAllVisibleAssetsInNetworkAssets = { _ in
      [NetworkAssets(
        network: .mockMainnet,
        tokens: [
          BraveWallet.NetworkInfo.mockMainnet.nativeToken.copy(asVisibleAsset: true),
          .mockERC721NFTToken.copy(asVisibleAsset: true),
          .mockUSDCToken.copy(asVisibleAsset: true)
        ],
        sortOrder: 0),
       NetworkAssets(
        network: .mockGoerli,
        tokens: [BraveWallet.NetworkInfo.mockGoerli.nativeToken.copy(asVisibleAsset: true)],
        sortOrder: 1)
      ]
    }
    
    let accountActivityStore = AccountActivityStore(
      account: account,
      observeAccountUpdates: false,
      keyringService: keyringService,
      walletService: walletService,
      rpcService: rpcService,
      assetRatioService: assetRatioService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      solTxManagerProxy: solTxManagerProxy,
      ipfsApi: ipfsApi,
      userAssetManager: mockAssetManager
    )
    
    let userVisibleAssetsException = expectation(description: "accountActivityStore-assetStores")
    accountActivityStore.$userVisibleAssets
      .dropFirst()
      .collect(2)
      .sink { userVisibleAssets in
        defer { userVisibleAssetsException.fulfill() }
        XCTAssertEqual(userVisibleAssets.count, 2) // empty assets, populated assets
        guard let lastUpdatedVisibleAssets = userVisibleAssets.last else {
          XCTFail("Unexpected test result")
          return
        }
        XCTAssertEqual(lastUpdatedVisibleAssets.count, 3)
        
        XCTAssertEqual(lastUpdatedVisibleAssets[0].token.symbol, BraveWallet.NetworkInfo.mockMainnet.nativeToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleAssets[0].network, BraveWallet.NetworkInfo.mockMainnet)
        XCTAssertEqual(lastUpdatedVisibleAssets[0].totalBalance, mockEthDecimalBalance)
        XCTAssertEqual(lastUpdatedVisibleAssets[0].price, self.mockAssetPrices[safe: 0]?.price ?? "")

        XCTAssertEqual(lastUpdatedVisibleAssets[1].token.symbol, BraveWallet.BlockchainToken.mockUSDCToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleAssets[1].network, BraveWallet.NetworkInfo.mockMainnet)
        XCTAssertEqual(lastUpdatedVisibleAssets[1].totalBalance, mockERC20DecimalBalance)
        XCTAssertEqual(lastUpdatedVisibleAssets[1].price, self.mockAssetPrices[safe: 1]?.price ?? "")
      }
      .store(in: &cancellables)
    
    let userVisibleNFTsException = expectation(description: "accountActivityStore-userVisibleNFTs")
    XCTAssertTrue(accountActivityStore.userVisibleNFTs.isEmpty)  // Initial state
    accountActivityStore.$userVisibleNFTs
      .dropFirst()
      .collect(2)
      .sink { userVisibleNFTs in
        defer { userVisibleNFTsException.fulfill() }
        XCTAssertEqual(userVisibleNFTs.count, 2) // empty nfts, populated nfts
        guard let lastUpdatedVisibleNFTs = userVisibleNFTs.last else {
          XCTFail("Unexpected test result")
          return
        }
        XCTAssertEqual(lastUpdatedVisibleNFTs.count, 1)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.token.symbol, BraveWallet.BlockchainToken.mockERC721NFTToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.balanceForAccounts[account.address], Int(mockNFTBalance))
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.imageURLString, mockERC721Metadata.imageURLString)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.name, mockERC721Metadata.name)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.description, mockERC721Metadata.description)
      }.store(in: &cancellables)
    
    let transactionSummariesExpectation = expectation(description: "accountActivityStore-transactions")
    XCTAssertTrue(accountActivityStore.transactionSummaries.isEmpty)
    accountActivityStore.$transactionSummaries
      .dropFirst()
      .sink { transactionSummaries in
        defer { transactionSummariesExpectation.fulfill() }
        // summaries are tested in `TransactionParserTests`, just verify they are populated with correct tx
        XCTAssertEqual(transactionSummaries.count, 2)
        XCTAssertEqual(transactionSummaries[safe: 0]?.txInfo, ethSendTxCopy)
        XCTAssertEqual(transactionSummaries[safe: 0]?.txInfo.chainId, ethSendTxCopy.chainId)
        XCTAssertEqual(transactionSummaries[safe: 1]?.txInfo, goerliSwapTxCopy)
        XCTAssertEqual(transactionSummaries[safe: 1]?.txInfo.chainId, goerliSwapTxCopy.chainId)
      }.store(in: &cancellables)
    
    accountActivityStore.update()

    waitForExpectations(timeout: 1) { error in
      XCTAssertNil(error)
    }
  }
  
  func testUpdateSolanaAccount() {
    let firstTransactionDate = Date(timeIntervalSince1970: 1636399671) // Monday, November 8, 2021 7:27:51 PM
    let account: BraveWallet.AccountInfo = .mockSolAccount
    let mockLamportBalance: UInt64 = 3876535000 // ~3.8765 SOL
    let mockSolDecimalBalance: Double = 3.8765 // rounded
    
    let mockSpdTokenBalance: Double = 0
    let mockSolanaNFTTokenBalance: Double = 1
    
    let mockSplTokenBalances: [String: String] = [
      BraveWallet.BlockchainToken.mockSpdToken.contractAddress: "\(mockSpdTokenBalance)",
      BraveWallet.BlockchainToken.mockSolanaNFTToken.contractAddress: "\(mockSolanaNFTTokenBalance)"
    ]
    
    let mockSolMetadata: NFTMetadata = .init(imageURLString: "sol.mock.image.url", name: "sol mock nft name", description: "sol mock nft description")
    
    let solSendTxCopy = BraveWallet.TransactionInfo.previewConfirmedSolSystemTransfer.copy() as! BraveWallet.TransactionInfo // default in mainnet
    let solTestnetSendTxCopy = BraveWallet.TransactionInfo.previewConfirmedSolTokenTransfer.copy() as! BraveWallet.TransactionInfo
    solTestnetSendTxCopy.chainId = BraveWallet.SolanaTestnet
    
    let (keyringService, rpcService, walletService, blockchainRegistry, assetRatioService, txService, solTxManagerProxy, ipfsApi) = setupServices(
      mockLamportBalance: mockLamportBalance,
      mockSplTokenBalances: mockSplTokenBalances,
      transactions: [solTestnetSendTxCopy, solSendTxCopy].enumerated().map { (index, tx) in
        // transactions sorted by created time, make sure they are in-order
        tx.createdTime = firstTransactionDate.addingTimeInterval(TimeInterval(index * 10))
        return tx
      }
    )
    
    let mockAssetManager = TestableWalletUserAssetManager()
    mockAssetManager._getAllVisibleAssetsInNetworkAssets = { _ in
      [
        NetworkAssets(
        network: .mockSolana,
        tokens: [
          BraveWallet.NetworkInfo.mockSolana.nativeToken.copy(asVisibleAsset: true),
          .mockSolanaNFTToken.copy(asVisibleAsset: true),
          .mockSpdToken.copy(asVisibleAsset: true)
        ],
        sortOrder: 0),
       NetworkAssets(
        network: .mockSolanaTestnet,
        tokens: [
          BraveWallet.NetworkInfo.mockSolanaTestnet.nativeToken.copy(asVisibleAsset: true)
        ],
        sortOrder: 1)
      ]
    }
    
    let accountActivityStore = AccountActivityStore(
      account: account,
      observeAccountUpdates: false,
      keyringService: keyringService,
      walletService: walletService,
      rpcService: rpcService,
      assetRatioService: assetRatioService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      solTxManagerProxy: solTxManagerProxy,
      ipfsApi: ipfsApi,
      userAssetManager: mockAssetManager
    )
    
    let userVisibleAssetsExpectation = expectation(description: "accountActivityStore-assetStores")
    accountActivityStore.$userVisibleAssets
      .dropFirst()
      .collect(2)
      .sink { userVisibleAssets in
        defer { userVisibleAssetsExpectation.fulfill() }
        XCTAssertEqual(userVisibleAssets.count, 2) // empty assets, populated assets
        guard let lastUpdatedVisibleAssets = userVisibleAssets.last else {
          XCTFail("Unexpected test result")
          return
        }
        XCTAssertEqual(lastUpdatedVisibleAssets.count, 3)
        
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 0]?.token.symbol, BraveWallet.NetworkInfo.mockSolana.nativeToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 0]?.network, BraveWallet.NetworkInfo.mockSolana)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 0]?.totalBalance, mockSolDecimalBalance)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 0]?.price, self.mockAssetPrices[safe: 2]?.price ?? "")

        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 1]?.token.symbol, BraveWallet.BlockchainToken.mockSpdToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 1]?.network, BraveWallet.NetworkInfo.mockSolana)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 1]?.totalBalance, mockSpdTokenBalance)
        XCTAssertEqual(lastUpdatedVisibleAssets[safe: 1]?.price, self.mockAssetPrices[safe: 3]?.price ?? "")
      }
      .store(in: &cancellables)
    
    let userVisibleNFTsExpectation = expectation(description: "accountActivityStore-userVisibleNFTs")
    XCTAssertTrue(accountActivityStore.userVisibleNFTs.isEmpty)  // Initial state
    accountActivityStore.$userVisibleNFTs
      .dropFirst()
      .collect(2)
      .sink { userVisibleNFTs in
        defer { userVisibleNFTsExpectation.fulfill() }
        XCTAssertEqual(userVisibleNFTs.count, 2) // empty nfts, populated nfts
        guard let lastUpdatedVisibleNFTs = userVisibleNFTs.last else {
          XCTFail("Unexpected test result")
          return
        }
        XCTAssertEqual(lastUpdatedVisibleNFTs.count, 1)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.token.symbol, BraveWallet.BlockchainToken.mockSolanaNFTToken.symbol)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.balanceForAccounts[account.address], Int(mockSolanaNFTTokenBalance))
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.imageURLString, mockSolMetadata.imageURLString)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.name, mockSolMetadata.name)
        XCTAssertEqual(lastUpdatedVisibleNFTs[safe: 0]?.nftMetadata?.description, mockSolMetadata.description)
      }.store(in: &cancellables)
    
    let transactionSummariesExpectation = expectation(description: "accountActivityStore-transactions")
    XCTAssertTrue(accountActivityStore.transactionSummaries.isEmpty)
    accountActivityStore.$transactionSummaries
      .dropFirst()
      .sink { transactionSummaries in
        defer { transactionSummariesExpectation.fulfill() }
        // summaries are tested in `TransactionParserTests`, just verify they are populated with correct tx
        XCTAssertEqual(transactionSummaries.count, 2)
        XCTAssertEqual(transactionSummaries[safe: 0]?.txInfo, solSendTxCopy)
        XCTAssertEqual(transactionSummaries[safe: 0]?.txInfo.chainId, solSendTxCopy.chainId)
        XCTAssertEqual(transactionSummaries[safe: 1]?.txInfo, solTestnetSendTxCopy)
        XCTAssertEqual(transactionSummaries[safe: 1]?.txInfo.chainId, solTestnetSendTxCopy.chainId)
      }.store(in: &cancellables)
    
    accountActivityStore.update()

    waitForExpectations(timeout: 1) { error in
      XCTAssertNil(error)
    }
  }
}
