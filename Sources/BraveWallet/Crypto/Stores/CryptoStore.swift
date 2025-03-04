// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import BraveCore
import Combine
import Preferences
import Data
import BraveUI

enum PendingRequest: Equatable {
  case transactions([BraveWallet.TransactionInfo])
  case addChain(BraveWallet.AddChainRequest)
  case switchChain(BraveWallet.SwitchChainRequest)
  case addSuggestedToken(BraveWallet.AddSuggestTokenRequest)
  case signMessage([BraveWallet.SignMessageRequest])
  case getEncryptionPublicKey(BraveWallet.GetEncryptionPublicKeyRequest)
  case decrypt(BraveWallet.DecryptRequest)
  case signTransaction([BraveWallet.SignTransactionRequest])
  case signAllTransactions([BraveWallet.SignAllTransactionsRequest])
}

extension PendingRequest: Identifiable {
  var id: String {
    switch self {
    case let .transactions(transactions): return "transactions-\(transactions.map(\.id))"
    case let .addChain(request): return "addChain-\(request.networkInfo.chainId)"
    case let .switchChain(chainRequest): return "switchChain-\(chainRequest.chainId)"
    case let .addSuggestedToken(tokenRequest): return "addSuggestedToken-\(tokenRequest.token.id)"
    case let .signMessage(signRequests): return "signMessage-\(signRequests.map(\.id))"
    case let .getEncryptionPublicKey(request): return "getEncryptionPublicKey-\(request.address)-\(request.requestId)"
    case let .decrypt(request): return "decrypt-\(request.address)-\(request.requestId)"
    case let .signTransaction(requests): return "signTransaction-\(requests.map(\.id))"
    case let .signAllTransactions(requests): return "signAllTransactions-\(requests.map(\.id))"
    }
  }
}

enum WebpageRequestResponse: Equatable {
  case switchChain(approved: Bool, requestId: String)
  case addNetwork(approved: Bool, chainId: String)
  case addSuggestedToken(approved: Bool, token: BraveWallet.BlockchainToken)
  case signMessage(approved: Bool, id: Int32)
  case getEncryptionPublicKey(approved: Bool, requestId: String)
  case decrypt(approved: Bool, requestId: String)
  case signTransaction(approved: Bool, id: Int32)
  case signAllTransactions(approved: Bool, id: Int32)
}

public class CryptoStore: ObservableObject {
  public let networkStore: NetworkStore
  public let portfolioStore: PortfolioStore
  let nftStore: NFTStore
  let transactionsActivityStore: TransactionsActivityStore
  let marketStore: MarketStore
  
  @Published var buySendSwapDestination: BuySendSwapDestination? {
    didSet {
      if buySendSwapDestination == nil {
        closeBSSStores()
      }
    }
  }
  @Published var isPresentingAssetSearch: Bool = false
  @Published var isPresentingPendingRequest: Bool = false {
    didSet {
      if !isPresentingPendingRequest {
        confirmationStore = nil
      }
    }
  }
  @Published private(set) var pendingRequest: PendingRequest? {
    didSet {
      if pendingRequest == nil {
        isPresentingPendingRequest = false
        return
      }
      // Verify a new request is available
      guard pendingRequest != oldValue, pendingRequest != nil else { return }
      // If we set these before the send or swap screens disappear for some reason it may crash
      // within the SwiftUI runtime or fail to dismiss. Delaying it to give time for the
      // animation to complete fixes it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.isPresentingPendingRequest = true
      }
    }
  }
  /// The origin of the active tab (if applicable). Used for fetching/selecting network for the DApp origin.
  public var origin: URLOrigin? {
    didSet {
      networkStore.origin = origin
    }
  }
  
  private let keyringService: BraveWalletKeyringService
  private let rpcService: BraveWalletJsonRpcService
  private let walletService: BraveWalletBraveWalletService
  private let assetRatioService: BraveWalletAssetRatioService
  private let swapService: BraveWalletSwapService
  let blockchainRegistry: BraveWalletBlockchainRegistry
  private let txService: BraveWalletTxService
  private let ethTxManagerProxy: BraveWalletEthTxManagerProxy
  private let solTxManagerProxy: BraveWalletSolanaTxManagerProxy
  private let ipfsApi: IpfsAPI
  private let userAssetManager: WalletUserAssetManager
  private var isUpdatingUserAssets: Bool = false
  private var autoDiscoveredAssets: [BraveWallet.BlockchainToken] = []
  
  public init(
    keyringService: BraveWalletKeyringService,
    rpcService: BraveWalletJsonRpcService,
    walletService: BraveWalletBraveWalletService,
    assetRatioService: BraveWalletAssetRatioService,
    swapService: BraveWalletSwapService,
    blockchainRegistry: BraveWalletBlockchainRegistry,
    txService: BraveWalletTxService,
    ethTxManagerProxy: BraveWalletEthTxManagerProxy,
    solTxManagerProxy: BraveWalletSolanaTxManagerProxy,
    ipfsApi: IpfsAPI,
    origin: URLOrigin? = nil
  ) {
    self.keyringService = keyringService
    self.rpcService = rpcService
    self.walletService = walletService
    self.assetRatioService = assetRatioService
    self.swapService = swapService
    self.blockchainRegistry = blockchainRegistry
    self.txService = txService
    self.ethTxManagerProxy = ethTxManagerProxy
    self.solTxManagerProxy = solTxManagerProxy
    self.ipfsApi = ipfsApi
    self.userAssetManager = WalletUserAssetManager(rpcService: rpcService, walletService: walletService)
    self.origin = origin
    
    self.networkStore = .init(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      swapService: swapService,
      userAssetManager: userAssetManager,
      origin: origin
    )
    self.portfolioStore = .init(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      assetRatioService: assetRatioService,
      blockchainRegistry: blockchainRegistry,
      ipfsApi: ipfsApi,
      userAssetManager: userAssetManager
    )
    self.nftStore = .init(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      assetRatioService: assetRatioService,
      blockchainRegistry: blockchainRegistry,
      ipfsApi: ipfsApi,
      userAssetManager: userAssetManager
    )
    self.transactionsActivityStore = .init(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      assetRatioService: assetRatioService,
      blockchainRegistry: blockchainRegistry,
      txService: txService,
      solTxManagerProxy: solTxManagerProxy,
      userAssetManager: userAssetManager
    )
    self.marketStore = .init(
      assetRatioService: assetRatioService,
      blockchainRegistry: blockchainRegistry,
      rpcService: rpcService,
      walletService: walletService
    )
    
    self.keyringService.add(self)
    self.txService.add(self)
    self.rpcService.add(self)
    self.walletService.add(self)
    
    Preferences.Wallet.migrateCoreToWalletUserAssetCompleted.observe(from: self)
    
    isUpdatingUserAssets = true
    userAssetManager.migrateUserAssets() { [weak self] in
      self?.isUpdatingUserAssets = false
      self?.updateAssets()
    }
  }
  
  private var buyTokenStore: BuyTokenStore?
  func openBuyTokenStore(_ prefilledToken: BraveWallet.BlockchainToken?) -> BuyTokenStore {
    if let store = buyTokenStore {
      return store
    }
    let store = BuyTokenStore(
      blockchainRegistry: blockchainRegistry,
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      assetRatioService: assetRatioService,
      prefilledToken: prefilledToken
    )
    buyTokenStore = store
    return store
  }
  
  private var sendTokenStore: SendTokenStore?
  func openSendTokenStore(_ prefilledToken: BraveWallet.BlockchainToken?) -> SendTokenStore {
    if let store = sendTokenStore {
      return store
    }
    let store = SendTokenStore(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      assetRatioService: assetRatioService,
      ethTxManagerProxy: ethTxManagerProxy,
      solTxManagerProxy: solTxManagerProxy,
      prefilledToken: prefilledToken,
      ipfsApi: ipfsApi,
      userAssetManager: userAssetManager
    )
    sendTokenStore = store
    return store
  }
  
  private var swapTokenStore: SwapTokenStore?
  func openSwapTokenStore(_ prefilledToken: BraveWallet.BlockchainToken?) -> SwapTokenStore {
    if let store = swapTokenStore {
      return store
    }
    let store = SwapTokenStore(
      keyringService: keyringService,
      blockchainRegistry: blockchainRegistry,
      rpcService: rpcService,
      swapService: swapService,
      txService: txService,
      walletService: walletService,
      ethTxManagerProxy: ethTxManagerProxy,
      solTxManagerProxy: solTxManagerProxy,
      userAssetManager: userAssetManager,
      prefilledToken: prefilledToken
    )
    swapTokenStore = store
    return store
  }
  
  private var assetDetailStore: AssetDetailStore?
  func assetDetailStore(for assetDetailType: AssetDetailType) -> AssetDetailStore {
    if let store = assetDetailStore, store.assetDetailType.id == assetDetailType.id {
      return store
    }
    let store = AssetDetailStore(
      assetRatioService: assetRatioService,
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      solTxManagerProxy: solTxManagerProxy,
      swapService: swapService,
      userAssetManager: userAssetManager,
      assetDetailType: assetDetailType
    )
    assetDetailStore = store
    return store
  }
  
  func closeAssetDetailStore(for assetDetailType: AssetDetailType) {
    if let store = assetDetailStore, store.assetDetailType.id == assetDetailType.id {
      assetDetailStore = nil
    }
  }
  
  private var accountActivityStore: AccountActivityStore?
  func accountActivityStore(
    for account: BraveWallet.AccountInfo,
    observeAccountUpdates: Bool
  ) -> AccountActivityStore {
    if let store = accountActivityStore,
       store.account.address == account.address,
       store.observeAccountUpdates == observeAccountUpdates {
      return store
    }
    let store = AccountActivityStore(
      account: account,
      observeAccountUpdates: observeAccountUpdates,
      keyringService: keyringService,
      walletService: walletService,
      rpcService: rpcService,
      assetRatioService: assetRatioService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      solTxManagerProxy: solTxManagerProxy,
      ipfsApi: ipfsApi,
      userAssetManager: userAssetManager
    )
    accountActivityStore = store
    return store
  }
  
  func closeAccountActivityStore(for account: BraveWallet.AccountInfo) {
    if let store = accountActivityStore, store.account.address == account.address {
      accountActivityStore = nil
    }
  }
  
  func closeBSSStores() {
    buyTokenStore = nil
    sendTokenStore = nil
    swapTokenStore = nil
  }
  
  private var confirmationStore: TransactionConfirmationStore?
  func openConfirmationStore() -> TransactionConfirmationStore {
    if let store = confirmationStore {
      return store
    }
    let store = TransactionConfirmationStore(
      assetRatioService: assetRatioService,
      rpcService: rpcService,
      txService: txService,
      blockchainRegistry: blockchainRegistry,
      walletService: walletService,
      ethTxManagerProxy: ethTxManagerProxy,
      keyringService: keyringService,
      solTxManagerProxy: solTxManagerProxy,
      userAssetManager: userAssetManager
    )
    confirmationStore = store
    return store
  }
  
  public private(set) lazy var settingsStore = SettingsStore(
    keyringService: keyringService,
    walletService: walletService,
    rpcService: rpcService,
    txService: txService,
    ipfsApi: ipfsApi
  )
  
  private var nftDetailStore: NFTDetailStore?
  func nftDetailStore(for nft: BraveWallet.BlockchainToken, nftMetadata: NFTMetadata?) -> NFTDetailStore {
    if let store = nftDetailStore, store.nft.id == nft.id {
      return store
    }
    let store = NFTDetailStore(
      rpcService: rpcService,
      ipfsApi: ipfsApi,
      nft: nft,
      nftMetadata: nftMetadata
    )
    nftDetailStore = store
    return store
  }
  
  func closeNFTDetailStore(for nft: BraveWallet.BlockchainToken) {
    if let store = nftDetailStore, store.nft.id == nft.id {
      nftDetailStore = nil
    }
  }
  
  // This will be called when users exit from edit visible asset screen
  // so that Portfolio and NFT tabs will update assets
  func updateAssets() {
    portfolioStore.update()
    nftStore.update()
  }
  
  func prepare(isInitialOpen: Bool = false) {
    Task { @MainActor in
      if isInitialOpen {
        walletService.discoverAssetsOnAllSupportedChains()
      }
      
      let pendingTransactions = await fetchPendingTransactions()
      var newPendingRequest: PendingRequest?
      if !pendingTransactions.isEmpty {
        newPendingRequest = .transactions(pendingTransactions)
      } else if let store = confirmationStore, !store.isReadyToBeDismissed {
        /*
         We need to check if Tx Confirmation modal is ready
         to be dismissed. It could be not ready as there is no pending tx
         but an active tx is being shown its different state like
         loading, submitted, completed or failed.
         As such we need to continue displaying Tx Confirmation until the
         user taps Ok/Close on the status overlay.
         */
        newPendingRequest = .transactions([])
      } else {
        // check for webpage requests
        newPendingRequest = await fetchPendingWebpageRequest()
      }
      // Verify this new `newPendingRequest` isn't the same as the current
      // `pendingRequest` because re-assigning the same request could cause
      // present of a previously dismissed / ignored pending request (#6750).
      guard newPendingRequest?.id != self.pendingRequest?.id else { return }
      if self.buySendSwapDestination != nil && newPendingRequest != nil {
        // Dismiss any buy send swap open to show the newPendingRequest
        self.buySendSwapDestination = nil
      }
      self.pendingRequest = newPendingRequest
    }
  }

  @MainActor
  func fetchPendingTransactions() async -> [BraveWallet.TransactionInfo] {
    let allKeyrings = await keyringService.keyrings(for: WalletConstants.supportedCoinTypes)
    var allChainIdsForCoin: [BraveWallet.CoinType: [String]] = [:]
    for coin in WalletConstants.supportedCoinTypes {
      let allNetworks = await rpcService.allNetworks(coin)
      allChainIdsForCoin[coin] = allNetworks.map(\.chainId)
    }
    return await txService.pendingTransactions(chainIdsForCoin: allChainIdsForCoin, for: allKeyrings)
  }

  @MainActor
  func fetchPendingWebpageRequest() async -> PendingRequest? {
    if let chainRequest = await rpcService.pendingAddChainRequests().first {
      return .addChain(chainRequest)
    } else if case let signTransactionRequests = await walletService.pendingSignTransactionRequests(), !signTransactionRequests.isEmpty {
      return .signTransaction(signTransactionRequests)
    } else if case let signAllTransactionsRequests = await walletService.pendingSignAllTransactionsRequests(), !signAllTransactionsRequests.isEmpty {
      return .signAllTransactions(signAllTransactionsRequests)
    } else if case let signMessageRequests = await walletService.pendingSignMessageRequests(), !signMessageRequests.isEmpty {
      return .signMessage(signMessageRequests)
    } else if let switchRequest = await rpcService.pendingSwitchChainRequests().first {
      return .switchChain(switchRequest)
    } else if let addTokenRequest = await walletService.pendingAddSuggestTokenRequests().first {
      return .addSuggestedToken(addTokenRequest)
    } else if let getEncryptionPublicKeyRequest = await walletService.pendingGetEncryptionPublicKeyRequests().first {
      return .getEncryptionPublicKey(getEncryptionPublicKeyRequest)
    } else if let decryptRequest = await walletService.pendingDecryptRequests().first {
      return .decrypt(decryptRequest)
    } else {
      return nil
    }
  }
  
  /// Determines if a pending request is available. We cannot simply check `pendingRequest` as it will be nil when the request is dismissed without accept/reject.
  @MainActor
  public func isPendingRequestAvailable() async -> Bool {
    let pendingTransactions = await fetchPendingTransactions()
    if !pendingTransactions.isEmpty {
      return true
    } else if let store = confirmationStore, !store.isReadyToBeDismissed {
      // Even though pendingTransaction is empty, however we still need
      // to check if TransactionConfirmationView is still displaying
      // an transaction in a different status.
      return true
    }
    let pendingRequest = await fetchPendingWebpageRequest()
    if self.pendingRequest == nil, pendingRequest != nil {
      self.pendingRequest = pendingRequest
    }
    return pendingRequest != nil
  }

  // Helper to store the completion block of an Add Network dapp request.
  typealias AddNetworkCompletion = (_ error: String?) -> Void
  // The completion closure(s) are handled in `onAddEthereumChainRequestCompleted`
  // when we determine if the chain was added successfully or not.
  var addNetworkDappRequestCompletion: [String: AddNetworkCompletion] = [:]
  
  func handleWebpageRequestResponse(
    _ response: WebpageRequestResponse,
    completion: ((_ error: String?) -> Void)? = nil
  ) {
    switch response {
    case let .switchChain(approved, requestId):
      rpcService.notifySwitchChainRequestProcessed(requestId, approved: approved)
    case let .addNetwork(approved, chainId):
      // for add network request, approval requires network call so we must
      // wait for `onAddEthereumChainRequestCompleted` to know success/failure
      if approved, let completion {
        // store `completion` closure until notified of `onAddEthereumChainRequestCompleted` event
        addNetworkDappRequestCompletion[chainId] = completion
        rpcService.addEthereumChainRequestCompleted(chainId, approved: approved)
      } else { // not approved, or no completion closure provided.
        completion?(nil)
        rpcService.addEthereumChainRequestCompleted(chainId, approved: approved)
      }
      return
    case let .addSuggestedToken(approved, token):
      if approved {
        userAssetManager.addUserAsset(token) { [weak self] in
          self?.updateAssets()
        }
      }
      walletService.notifyAddSuggestTokenRequestsProcessed(approved, contractAddresses: [token.contractAddress])
    case let .signMessage(approved, id):
      walletService.notifySignMessageRequestProcessed(approved, id: id, signature: nil, error: nil)
    case let .getEncryptionPublicKey(approved, requestId):
      walletService.notifyGetPublicKeyRequestProcessed(requestId, approved: approved)
    case let .decrypt(approved, requestId):
      walletService.notifyDecryptRequestProcessed(requestId, approved: approved)
    case let .signTransaction(approved, id):
      walletService.notifySignTransactionRequestProcessed(approved, id: id, signature: nil, error: nil)
    case let .signAllTransactions(approved, id):
      walletService.notifySignAllTransactionsRequestProcessed(approved, id: id, signatures: nil, error: nil)
    }
    pendingRequest = nil
    completion?(nil)
  }
  
  public func rejectAllPendingWebpageRequests() {
    Task { @MainActor in
      let pendingAddChainRequests = await rpcService.pendingAddChainRequests()
      pendingAddChainRequests.forEach {
        handleWebpageRequestResponse(.addNetwork(approved: false, chainId: $0.networkInfo.chainId))
      }
      let pendingSignMessageRequests = await walletService.pendingSignMessageRequests()
      pendingSignMessageRequests.forEach {
        handleWebpageRequestResponse(.signMessage(approved: false, id: $0.id))
      }
      let pendingSwitchChainRequests = await rpcService.pendingSwitchChainRequests()
      pendingSwitchChainRequests.forEach {
        handleWebpageRequestResponse(.switchChain(approved: false, requestId: $0.requestId))
      }
      let pendingAddSuggestedTokenRequets = await walletService.pendingAddSuggestTokenRequests()
      pendingAddSuggestedTokenRequets.forEach {
        handleWebpageRequestResponse(.addSuggestedToken(approved: false, token: $0.token))
      }
      let pendingGetEncryptionPublicKeyRequests = await walletService.pendingGetEncryptionPublicKeyRequests()
      pendingGetEncryptionPublicKeyRequests.forEach {
        handleWebpageRequestResponse(.getEncryptionPublicKey(approved: false, requestId: $0.requestId))
      }
      let pendingDecryptRequests = await walletService.pendingDecryptRequests()
      pendingDecryptRequests.forEach {
        handleWebpageRequestResponse(.decrypt(approved: false, requestId: $0.requestId))
      }
    }
  }
}

extension CryptoStore: BraveWalletTxServiceObserver {
  public func onNewUnapprovedTx(_ txInfo: BraveWallet.TransactionInfo) {
    prepare()
  }
  public func onUnapprovedTxUpdated(_ txInfo: BraveWallet.TransactionInfo) {
    prepare()
  }
  public func onTransactionStatusChanged(_ txInfo: BraveWallet.TransactionInfo) {
    prepare()
  }
  public func onTxServiceReset() {
    prepare()
  }
}

extension CryptoStore: BraveWalletKeyringServiceObserver {
  public func keyringReset() {
    WalletProviderPermissionRequestsManager.shared.cancelAllPendingRequests(for: [.eth, .sol])
    WalletProviderAccountCreationRequestManager.shared.cancelAllPendingRequests(coins: [.eth, .sol])
    rejectAllPendingWebpageRequests()
  }
  public func keyringCreated(_ keyringId: BraveWallet.KeyringId) {
    Task { @MainActor [weak self] in
      if let newCoin = WalletConstants.supportedCoinTypes.first(where: { $0.keyringId == keyringId }) {
        self?.userAssetManager.migrateUserAssets(for: newCoin, completion: {
          self?.updateAssets()
        })
      }
    }
  }
  public func keyringRestored(_ keyringId: BraveWallet.KeyringId) {
    // This observer method will only get called when user restore a wallet
    // from the lock screen
    // We will need to
    // 1. reset wallet user asset migration flag
    // 2. wipe user assets local storage
    // 3. migrate user assets with new keyring
    guard !isUpdatingUserAssets else { return }
    isUpdatingUserAssets = true
    Preferences.Wallet.migrateCoreToWalletUserAssetCompleted.reset()
    WalletUserAssetGroup.removeAllGroup() { [weak self] in
      self?.userAssetManager.migrateUserAssets(completion: {
        self?.updateAssets()
        self?.isUpdatingUserAssets = false
      })
    }
  }
  public func locked() {
    isPresentingPendingRequest = false
  }
  public func unlocked() {
  }
  public func backedUp() {
  }
  public func accountsChanged() {
  }
  public func autoLockMinutesChanged() {
  }
  public func selectedWalletAccountChanged(_ account: BraveWallet.AccountInfo) {
  }
  public func selectedDappAccountChanged(_ coin: BraveWallet.CoinType, account: BraveWallet.AccountInfo?) {
  }
  public func accountsAdded(_ addedAccounts: [BraveWallet.AccountInfo]) {
  }
}

extension CryptoStore: BraveWalletJsonRpcServiceObserver {
  public func chainChangedEvent(_ chainId: String, coin: BraveWallet.CoinType, origin: URLOrigin?) {
    // if user had just changed networks, there is a potential race condition
    // blocking presenting pendingRequest here, as Network Selection might still be on screen
    // by delaying here instead of at present we only delay after chain changes (#6750)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.prepare()
    }
  }
  
  public func onAddEthereumChainRequestCompleted(_ chainId: String, error: String) {
    Task { @MainActor in
      if let addNetworkDappRequestCompletion = addNetworkDappRequestCompletion[chainId] {
        if error.isEmpty {
          let allNetworks = await rpcService.allNetworks(.eth)
          if let network = allNetworks.first(where: { $0.chainId == chainId }) {
            userAssetManager.addUserAsset(network.nativeToken) { [weak self] in
              self?.updateAssets()
            }
          }
        }
        addNetworkDappRequestCompletion(error.isEmpty ? nil : error)
        self.addNetworkDappRequestCompletion[chainId] = nil
      }
    }
  }
  
  public func onIsEip1559Changed(_ chainId: String, isEip1559: Bool) {
  }
}

extension CryptoStore: BraveWalletBraveWalletServiceObserver {
  public func onActiveOriginChanged(_ originInfo: BraveWallet.OriginInfo) {
  }
  
  public func onDefaultEthereumWalletChanged(_ wallet: BraveWallet.DefaultWallet) {
  }
  
  public func onDefaultSolanaWalletChanged(_ wallet: BraveWallet.DefaultWallet) {
  }
  
  public func onDefaultBaseCurrencyChanged(_ currency: String) {
  }
  
  public func onDefaultBaseCryptocurrencyChanged(_ cryptocurrency: String) {
  }
  
  public func onNetworkListChanged() {
    updateAssets()
  }
  
  public func onDiscoverAssetsStarted() {
  }
  
  public func onDiscoverAssetsCompleted(_ discoveredAssets: [BraveWallet.BlockchainToken]) {
    // Failsafe incase two CryptoStore's are initialized (see brave-ios #7804) and asset
    // migration is slow. Makes sure auto-discovered assets during asset migration to
    // CoreData are added after.
    if !isUpdatingUserAssets {
      for asset in discoveredAssets {
        userAssetManager.addUserAsset(asset, completion: nil)
      }
      if !discoveredAssets.isEmpty {
        updateAssets()
      }
    } else {
      autoDiscoveredAssets.append(contentsOf: discoveredAssets)
    }
  }
  
  public func onResetWallet() {
  }
}

extension CryptoStore: PreferencesObserver {
  public func preferencesDidChange(for key: String) {
    // we are only observing `Preferences.Wallet.migrateCoreToWalletUserAssetCompleted`
    if Preferences.Wallet.migrateCoreToWalletUserAssetCompleted.value, !autoDiscoveredAssets.isEmpty {
      for asset in autoDiscoveredAssets {
        userAssetManager.addUserAsset(asset, completion: nil)
      }
      autoDiscoveredAssets.removeAll()
      updateAssets()
    }
  }
}
