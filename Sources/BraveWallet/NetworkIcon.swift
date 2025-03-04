// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import BraveCore
import SwiftUI
import BraveUI

struct NetworkIcon: View {
  
  var network: BraveWallet.NetworkInfo

  @ScaledMetric var length: CGFloat = 30
  
  var body: some View {
    Group {
      if let (iconName, grayscale) = networkImageInfo {
        Image(iconName, bundle: .module)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .saturation(grayscale ? 0 : 1)
      } else if let urlString = network.iconUrls.first,
                let url = URL(string: urlString) {
        WebImageReader(url: url) { image in
          if let image = image {
            Image(uiImage: image)
              .aspectRatio(contentMode: .fit)
              .clipShape(Circle())
          } else {
            networkIconMonogram
          }
        }
      } else {
        networkIconMonogram
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(width: length, height: length)
  }
  
  private var networkIconMonogram: some View {
    Blockie(address: network.chainName)
      .overlay(
        Text(network.chainName.first?.uppercased() ?? "")
          .font(.system(size: length / 2, weight: .bold, design: .rounded))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
      )
  }
  
  private typealias NetworkImageInfo = (iconName: String, grayscale: Bool)
  private var networkImageInfo: NetworkImageInfo? {
    let isGrayscale = WalletConstants.supportedTestNetworkChainIds.contains(network.chainId)
    if let imageName = network.networkLogoName {
      return (imageName, isGrayscale)
    }
    return nil
  }
}
