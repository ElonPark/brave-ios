// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveCore
import Data
import Preferences

/// An object that wraps around an `AdblockEngine` and caches some results
/// and ensures information is always returned on the correct thread on the engine.
public class CachedAdBlockEngine {
  typealias CosmeticFilterModelTuple = (source: AdBlockEngineManager.Source, model: CosmeticFilterModel)
  typealias SelectorsTuple = (source: AdBlockEngineManager.Source, selectors: Set<String>)
  
  /// We cache the models so that they load faster when we need to poll information about the frame
  private var cachedCosmeticFilterModels = FifoDict<URL, CosmeticFilterModel?>()
  /// We cache the models so that they load faster when doing stats tracking or request blocking
  private var cachedShouldBlockResult = FifoDict<String, Bool>()
  /// We cache the user scripts so that they load faster on refreshes and back and forth
  private var cachedFrameScriptTypes = FifoDict<URL, Set<UserScriptType>>()
  
  private let engine: AdblockEngine
  private let serialQueue: DispatchQueue
  let source: AdBlockEngineManager.Source
  
  init(engine: AdblockEngine, source: AdBlockEngineManager.Source, serialQueue: DispatchQueue) {
    self.engine = engine
    self.source = source
    self.serialQueue = serialQueue
  }
  
  /// Checks the general and regional engines to see if the request should be blocked.
  func shouldBlock(requestURL: URL, sourceURL: URL, resourceType: AdblockEngine.ResourceType, isAggressiveMode: Bool) async -> Bool {
    return await withCheckedContinuation { continuation in
      serialQueue.async { [weak self] in
        let shouldBlock = self?.shouldBlock(
          requestURL: requestURL, sourceURL: sourceURL, resourceType: resourceType,
          isAggressiveMode: isAggressiveMode
        ) == true
        
        continuation.resume(returning: shouldBlock)
      }
    }
  }
  
  /// Returns all the models for this frame URL
  /// The results are cached per url, so you may call this method as many times for the same url without any performance implications.
  func cosmeticFilterModel(forFrameURL frameURL: URL) async throws -> CosmeticFilterModelTuple? {
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CosmeticFilterModelTuple?, Error>) in
      serialQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: nil)
          return
        }
        
        do {
          if let model = try self.cachedCosmeticFilterModel(forFrameURL: frameURL) {
            continuation.resume(returning: (self.source, model))
          } else {
            continuation.resume(returning: nil)
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
  /// Return the selectors that need to be hidden given the frameURL, ids and classes
  func selectorsForCosmeticRules(frameURL: URL, ids: [String], classes: [String]) async throws -> SelectorsTuple? {
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SelectorsTuple?, Error>) in
      serialQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: nil)
          return
        }
        
        do {
          let model = try self.cachedCosmeticFilterModel(forFrameURL: frameURL)
          
          let selectors = try self.engine.stylesheetForCosmeticRulesIncluding(
            classes: classes, ids: ids, exceptions: model?.exceptions ?? []
          )

          continuation.resume(returning: (self.source, Set(selectors)))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
  /// Return a cosmetic filter modelf or the given frameURL
  ///
  /// - Warning: The caller is responsible for syncing on the `serialQueue`
  private func cachedCosmeticFilterModel(forFrameURL frameURL: URL) throws -> CosmeticFilterModel? {
    if let result = self.cachedCosmeticFilterModels.getElement(frameURL) {
      return result
    }
    
    let model = try self.engine.cosmeticFilterModel(forFrameURL: frameURL)
    self.cachedCosmeticFilterModels.addElement(model, forKey: frameURL)
    return model
  }
  
  /// Checks the general and regional engines to see if the request should be blocked
  private func shouldBlock(requestURL: URL, sourceURL: URL, resourceType: AdblockEngine.ResourceType, isAggressiveMode: Bool) -> Bool {
    let key = [requestURL.absoluteString, sourceURL.absoluteString, resourceType.rawValue].joined(separator: "_")
    
    if let cachedResult = cachedShouldBlockResult.getElement(key) {
        return cachedResult
    }
    
    let shouldBlock = engine.shouldBlock(
      requestURL: requestURL,
      sourceURL: sourceURL,
      resourceType: resourceType,
      isAggressive: isAggressiveMode || self.source.isAlwaysAggressive
    )
    
    cachedShouldBlockResult.addElement(shouldBlock, forKey: key)
    return shouldBlock
  }
  
  /// This returns all the user script types for the given frame
  @MainActor func makeEngineScriptTypes(frameURL: URL, isMainFrame: Bool, domain: Domain, index: Int) async throws -> Set<UserScriptType> {
    if let userScriptTypes = cachedFrameScriptTypes.getElement(frameURL) {
      return userScriptTypes
    }
    
    // Add the selectors poller scripts for this frame
    var userScriptTypes: Set<UserScriptType> = []
    
    if let source = try await cosmeticFilterModel(forFrameURL: frameURL)?.model.injectedScript, !source.isEmpty {
      let configuration = UserScriptType.EngineScriptConfiguration(
        frameURL: frameURL, isMainFrame: isMainFrame, source: source, order: index,
        isDeAMPEnabled: Preferences.Shields.autoRedirectAMPPages.value
      )
      
      userScriptTypes.insert(.engineScript(configuration))
    }
      
    cachedFrameScriptTypes.addElement(userScriptTypes, forKey: frameURL)
    return userScriptTypes
  }
  
  /// Clear the caches.
  func clearCaches() {
    cachedCosmeticFilterModels = FifoDict()
    cachedShouldBlockResult = FifoDict()
    cachedFrameScriptTypes = FifoDict()
  }
  
  /// Returns a boolean indicating if the engine is enabled for the given domain.
  ///
  /// This is determined by checking the source of the engine and checking the appropriate shields.
  @MainActor func isEnabled(for domain: Domain) -> Bool {
    switch source {
    case .adBlock, .filterList, .filterListURL:
      // This engine source type is enabled only if shields are enabled
      // for the given domain
      return domain.isShieldExpected(.AdblockAndTp, considerAllShieldsOption: true)
    }
  }
  
  /// Create multiple engines from the given resources by grouping them by their source
  /// - Parameter resources: The resources to compile the engines from
  /// - Returns: An array of compilation results
  static func createEngines(
    from resources: [AdBlockEngineManager.ResourceWithVersion],
    scripletResourcesURL: URL?
  ) async -> [Result<CachedAdBlockEngine, Error>] {
    let groupedResources = Dictionary(grouping: resources, by: \.resource.source)
    
    return await groupedResources.asyncConcurrentMap { source, resources -> Result<CachedAdBlockEngine, Error> in
      do {
        let engine = try await createEngine(
          from: resources, source: source, scripletResourcesURL: scripletResourcesURL
        )
        return .success(engine)
      } catch {
        return .failure(error)
      }
    }
  }
  
  /// Create an engine from the given resources
  static func createEngine(
    from resources: [AdBlockEngineManager.ResourceWithVersion],
    source: AdBlockEngineManager.Source,
    scripletResourcesURL: URL?
  ) async throws -> CachedAdBlockEngine {
    return try await withCheckedThrowingContinuation { continuation in
      let serialQueue = DispatchQueue(label: "com.brave.WrappedAdBlockEngine.\(UUID().uuidString)")
      
      serialQueue.async {
        do {
          let engine = try AdblockEngine.createEngine(from: resources, scripletResourcesURL: scripletResourcesURL)
          let cachedEngine = CachedAdBlockEngine(engine: engine, source: source, serialQueue: serialQueue)
          continuation.resume(returning: cachedEngine)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
