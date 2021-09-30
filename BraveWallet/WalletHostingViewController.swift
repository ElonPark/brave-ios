// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI
import BraveCore

/// The initial wallet controller to present when the user wants to view their wallet
public class WalletHostingViewController: UIHostingController<CryptoView> {
  
  public init(walletStore: WalletStore) {
    super.init(
      rootView: CryptoView(
        walletStore: walletStore,
        keyringStore: walletStore.keyringStore
      )
    )
    rootView.dismissAction = { [unowned self] in
      self.dismiss(animated: true)
    }
  }
  
  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }
  
  // MARK: -
  
  public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    [.portrait, .portraitUpsideDown]
  }
  
  public override var shouldAutorotate: Bool {
    false
  }
}
