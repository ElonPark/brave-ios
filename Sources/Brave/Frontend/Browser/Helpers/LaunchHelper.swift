// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveCore
import Preferences
import BraveShields
import os

/// This class helps to prepare the browser during launch by ensuring the state of managers, resources and downloaders before performing additional tasks.
public actor LaunchHelper {
  public static let shared = LaunchHelper()
  static let signpost = OSSignposter(logger: ContentBlockerManager.log)
  private let currentBlocklistVersion: Float = 1.0
  
  /// Get the last version the user launched this application. This allows us to know what to re-compile.
  public var lastBlocklistVersion = Preferences.Option<Float?>(
    key: "launch_helper.last-launch-version", default: nil
  )
  
  private var loadTask: Task<(), Never>?
  private var areAdBlockServicesReady = false
  
  /// This method prepares the ad-block services one time so that multiple scenes can benefit from its results
  /// This is particularly important since we use a shared instance for most of our ad-block services.
  public func prepareAdBlockServices(adBlockService: AdblockService) async {
    // Check if ad-block services are already ready.
    // If so, we don't have to do anything
    guard !areAdBlockServicesReady else { return }
    
    // Check if we're still preparing the ad-block services
    // If so we await that task
    if let task = loadTask {
      return await task.value
    }
    
    // Otherwise prepare the services and await the task
    let task = Task {
      let signpostID = Self.signpost.makeSignpostID()
      let state = Self.signpost.beginInterval("blockingLaunchTask", id: signpostID)
      // We only want to compile the necessary content blockers during launch
      // We will compile other ones after launch
      let launchBlockModes = self.getFirstLaunchBlocklistModes()
      
      // Load cached data
      // This is done first because compileResources need their results
      async let filterListCache: Void = FilterListResourceDownloader.shared.loadFilterListSettingsAndCachedData()
      async let adblockResourceCache: Void = AdblockResourceDownloader.shared.loadCachedAndBundledDataIfNeeded(allowedModes: launchBlockModes)
      async let filterListURLCache: Void = FilterListCustomURLDownloader.shared.loadCachedFilterLists()
      _ = await (filterListCache, adblockResourceCache, filterListURLCache)
      Self.signpost.emitEvent("loadedCachedData", id: signpostID, "Loaded cached data")
      
      // Compile some engines
      await AdBlockEngineManager.shared.compileResources()
      Self.signpost.emitEvent("compileResources", id: signpostID, "Compiled engine resources")
      
      // This one is non-blocking
      performPostLoadTasks(adBlockService: adBlockService, loadedBlockModes: launchBlockModes)
      areAdBlockServicesReady = true
      Self.signpost.endInterval("blockingLaunchTask", state)
    }
    
    // Await the task and wait for the results
    self.loadTask = task
    await task.value
    self.loadTask = nil
  }
  
  /// Return the blocking modes we need to pre-compile on first launch.
  private func getFirstLaunchBlocklistModes() -> Set<ContentBlockerManager.BlockingMode> {
    guard let version = self.lastBlocklistVersion.value else {
      // If we don't have version, this is our first launch
      return ShieldPreferences.blockAdsAndTrackingLevel.firstLaunchBlockingModes
    }
    
    if version < currentBlocklistVersion {
      // We updated something and require things to be re-compiled
      return ShieldPreferences.blockAdsAndTrackingLevel.firstLaunchBlockingModes
    } else {
      // iOS caches content blockers. We only need to pre-compile things the first time (on first launch).
      // Since we didn't change anything and we know this isn't a first launch, we can return an empty set
      // So that subsequent relaunches are much faster
      return []
    }
  }
  
  /// Perform tasks that don't need to block the initial load (things that can happen happily in the background after the first page loads
  private func performPostLoadTasks(adBlockService: AdblockService, loadedBlockModes: Set<ContentBlockerManager.BlockingMode>) {
    // Here we need to load the remaining modes so they are ready should the user change their settings
    let remainingModes = ContentBlockerManager.BlockingMode.allCases.filter({ !loadedBlockModes.contains($0) })
    
    Task.detached(priority: .low) {
      let signpostID = Self.signpost.makeSignpostID()
      let state = Self.signpost.beginInterval("nonBlockingLaunchTask", id: signpostID)
      await FilterListResourceDownloader.shared.start(with: adBlockService)
      Self.signpost.emitEvent("FilterListResourceDownloader.shared.start", id: signpostID, "Started filter list downloader")
      await AdblockResourceDownloader.shared.loadCachedAndBundledDataIfNeeded(allowedModes: Set(remainingModes))
      Self.signpost.emitEvent("loadCachedAndBundledDataIfNeeded", id: signpostID, "Reloaded data for remaining modes")
      await AdblockResourceDownloader.shared.startFetching()
      Self.signpost.emitEvent("startFetching", id: signpostID, "Started fetching ad-block data")
      await AdBlockEngineManager.shared.startTimer()
      Self.signpost.emitEvent("startTimer", id: signpostID, "Started engine timer")
      
      /// Cleanup rule lists so we don't have dead rule lists
      let validBlocklistTypes = await self.getAllValidBlocklistTypes()
      await ContentBlockerManager.shared.cleaupInvalidRuleLists(validTypes: validBlocklistTypes)
      Self.signpost.endInterval("nonBlockingLaunchTask", state)
      
      // Update the setting
      await self.lastBlocklistVersion.value = self.currentBlocklistVersion
    }
  }
  
  /// Get all possible types of blocklist types available in this app, this includes actual and potential types
  /// This is used to delete old filter lists so that we clean up old stuff
  @MainActor private func getAllValidBlocklistTypes() -> Set<ContentBlockerManager.BlocklistType> {
    return FilterListStorage.shared.filterLists
      // All filter lists blocklist types
      .reduce(Set<ContentBlockerManager.BlocklistType>()) { partialResult, filterList in
        return partialResult.union([
          .filterList(componentId: filterList.entry.componentId, isAlwaysAggressive: filterList.isAlwaysAggressive)
        ])
      }
      // All generic types
      .union(
        ContentBlockerManager.GenericBlocklistType.allCases.map { .generic($0) }
      )
      // All custom filter list urls
      .union(
        CustomFilterListStorage.shared.filterListsURLs.map { .customFilterList(uuid: $0.setting.uuid) }
      )
  }
}

private extension ShieldLevel {
  /// Return a list of first launch content blocker modes that MUST be precompiled during launch
  var firstLaunchBlockingModes: Set<ContentBlockerManager.BlockingMode> {
    switch self {
    case .standard, .disabled:
      // Disabled setting may be overriden per domain so we need to treat it as standard
      // Aggressive needs to be included because some filter lists are aggressive only
      return [.general, .standard, .aggressive]
    case .aggressive:
      // If we have aggressive mode enabled, we never use standard
      // (until we allow domain specific aggressive mode)
      return [.general, .aggressive]
    }
  }
}
