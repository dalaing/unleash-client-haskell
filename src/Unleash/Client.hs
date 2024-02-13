{- |
Module      : Unleash.Client
Copyright   : Copyright © FINN.no AS, Inc. All rights reserved.
License     : MIT
Stability   : experimental

Functions and types that constitute an Unleash client SDK.

This module re-exports select constructors from [unleash-client-haskell-core](https://github.com/finn-no/unleash-client-haskell-core).
-}
module Unleash.Client (
    makeUnleashConfig,
    UnleashConfig (..),
    HasUnleash (..),
    registerClient,
    pollToggles,
    pushMetrics,
    isEnabled,
    tryIsEnabled,
    getVariant,
    tryGetVariant,
    -- Re-exports
    Context (..),
    emptyContext,
    VariantResponse (..),
) where

import Control.Concurrent.MVar
import Control.Monad (unless, void)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Reader (MonadReader, asks)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Client.TLS (newTlsManager)
import Servant.Client (BaseUrl, ClientEnv, ClientError, mkClientEnv)
import Unleash (Context (..), Features, MetricsPayload(MetricsPayload), RegisterPayload(RegisterPayload), VariantResponse(VariantResponse), emptyContext, emptyVariantResponse, featureGetVariant, featureIsEnabled)
import qualified Unleash
import Unleash.Internal.HttpClient (getAllClientFeatures, register, sendMetrics)

-- | Smart constructor for Unleash client configuration. Initializes the mutable variables properly.
makeUnleashConfig ::
    MonadIO m =>
    -- | Application name.
    Text ->
    -- | Instance identifier.
    Text ->
    -- | Unleash server base URL.
    BaseUrl ->
    -- | API key for authorization.
    Maybe Text ->
    -- | Configuration instance.
    m UnleashConfig
makeUnleashConfig applicationName instanceId serverUrl apiKey = do
    state <- liftIO newEmptyMVar
    metrics <- liftIO $ newMVar mempty
    metricsBucketStart <- liftIO $ getCurrentTime >>= newMVar
    manager <- newTlsManager
    let clientEnv = mkClientEnv manager serverUrl
    pure $
        UnleashConfig
            { applicationName = applicationName,
              instanceId = instanceId,
              state = state,
              statePollIntervalInSeconds = 4,
              metrics = metrics,
              metricsBucketStart = metricsBucketStart,
              metricsPushIntervalInSeconds = 8,
              apiKey = apiKey,
              httpClientEnvironment = clientEnv
            }

-- | Unleash client configuration. Use the smart constructor or make sure the mutable metrics variables are not empty.
data UnleashConfig = UnleashConfig
    { -- | Application name.
      applicationName :: Text,
      -- | Instance identifier.
      instanceId :: Text,
      -- | Full client feature set state.
      state :: MVar Features,
      -- | Feature set state update interval.
      statePollIntervalInSeconds :: Int,
      -- | Collected metrics state.
      metrics :: MVar [(Text, Bool)],
      -- | Current metrics bucket start time.
      metricsBucketStart :: MVar UTCTime,
      -- | Metrics sending interval.
      metricsPushIntervalInSeconds :: Int,
      -- | API key for authorization.
      apiKey :: Maybe Text,
      -- | HTTP client environment.
      httpClientEnvironment :: ClientEnv
    }

-- | Reader monad convenience class. Use this to get an Unleash configuration from inside of an application configuration (for example).
class HasUnleash r where
    getUnleashConfig :: r -> UnleashConfig

instance HasUnleash UnleashConfig where
    getUnleashConfig = id

-- | Register client for the Unleash server. Call this on application startup before calling the state poller and metrics pusher functions.
registerClient :: (HasUnleash r, MonadReader r m, MonadIO m) => m (Either ClientError ())
registerClient = do
    config <- asks getUnleashConfig
    now <- liftIO getCurrentTime
    let registrationPayload :: RegisterPayload
        registrationPayload =
            RegisterPayload
                { appName = applicationName config,
                  instanceId = instanceId config,
                  started = now,
                  intervalSeconds = metricsPushIntervalInSeconds config
                }
    void <$> register (httpClientEnvironment config) (apiKey config) registrationPayload

-- | Fetch the most recent feature toggle set from the Unleash server. Meant to be run every statePollIntervalInSeconds. Non-blocking.
pollToggles :: (HasUnleash r, MonadReader r m, MonadIO m) => m (Either ClientError ())
pollToggles = do
    config <- asks getUnleashConfig
    eitherFeatures <- getAllClientFeatures (httpClientEnvironment config) (apiKey config)
    either (const $ pure ()) (updateState $ state config) eitherFeatures
    pure . void $ eitherFeatures
    where
        updateState state value = do
            isUpdated <- liftIO $ tryPutMVar state value
            liftIO . unless isUpdated . void $ swapMVar state value

-- | Push metrics to the Unleash server. Meant to be run every metricsPushIntervalInSeconds. Blocks if the mutable metrics variables are empty.
pushMetrics :: (HasUnleash r, MonadReader r m, MonadIO m) => m (Either ClientError ())
pushMetrics = do
    config <- asks getUnleashConfig
    now <- liftIO getCurrentTime
    lastBucketStart <- liftIO $ swapMVar (metricsBucketStart config) now
    bucket <- liftIO $ swapMVar (metrics config) mempty
    let metricsPayload =
            MetricsPayload
                { appName = applicationName config,
                  instanceId = instanceId config,
                  start = lastBucketStart,
                  stop = now,
                  toggles = bucket
                }
    void <$> sendMetrics (httpClientEnvironment config) (apiKey config) metricsPayload

-- | Check if a feature is enabled or not. Blocks until first feature toggle set is received. Blocks if the mutable metrics variables are empty.
isEnabled ::
    (HasUnleash r, MonadReader r m, MonadIO m) =>
    -- | Feature toggle name.
    Text ->
    -- | Client context.
    Context ->
    -- | Whether or not the feature toggle is enabled.
    m Bool
isEnabled feature context = do
    config <- asks getUnleashConfig
    state <- liftIO . readMVar $ state config
    enabled <- featureIsEnabled state feature context
    pure enabled

-- | Check if a feature is enabled or not. Returns false for all toggles until first toggle set is received. Blocks if the mutable metrics variables are empty.
tryIsEnabled ::
    (HasUnleash r, MonadReader r m, MonadIO m) =>
    -- | Feature toggle name.
    Text ->
    -- | Client context.
    Context ->
    -- | Whether or not the feature toggle is enabled.
    m Bool
tryIsEnabled feature context = do
    config <- asks getUnleashConfig
    maybeState <- liftIO . tryReadMVar $ state config
    case maybeState of
        Just state -> do
            enabled <- featureIsEnabled state feature context
            pure enabled
        Nothing -> pure False

-- | Get a variant. Blocks until first feature toggle set is received.
getVariant ::
    (HasUnleash r, MonadReader r m, MonadIO m) =>
    -- | Feature toggle name.
    Text ->
    -- | Client context.
    Context ->
    -- | Variant.
    m VariantResponse
getVariant feature context = do
    config <- asks getUnleashConfig
    state <- liftIO . readMVar $ state config
    featureGetVariant state feature context

-- | Get a variant. Returns an empty variant until first toggle set is received.
tryGetVariant ::
    (HasUnleash r, MonadReader r m, MonadIO m) =>
    -- | Feature toggle name.
    Text ->
    -- | Client context.
    Context ->
    -- | Variant.
    m VariantResponse
tryGetVariant feature context = do
    config <- asks getUnleashConfig
    maybeState <- liftIO . tryReadMVar $ state config
    case maybeState of
        Just state -> do
            featureGetVariant state feature context
        Nothing -> pure emptyVariantResponse
