{-# LANGUAGE FlexibleInstances #-}

module Happstack.Server.Internal.MessageWrap (
        module Happstack.Server.Internal.MessageWrap
        ,defaultInputIter
   ) where

import Control.Concurrent.MVar (tryTakeMVar, tryPutMVar, putMVar)
import Control.Monad.Trans (MonadIO(liftIO))
import qualified Data.ByteString.Char8 as P
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.ByteString.UTF8  as U (toString)
import Data.Int (Int64)
import Happstack.Server.Internal.Types as H
import Happstack.Server.Internal.Multipart
import Happstack.Server.Internal.RFC822Headers (parseContentType)
import Happstack.Server.SURI as SURI

queryInput :: SURI -> [(String, Input)]
queryInput uri = formDecode (case SURI.query uri of
                               '?':r -> r
                               xs    -> xs)

-- | see 'defaultBodyPolicy'
data BodyPolicy
    = BodyPolicy { inputWorker :: Int64 -> Int64 -> Int64 -> InputWorker
                 , maxDisk     :: Int64 -- ^ maximum bytes for files uploaded in this 'Request'
                 , maxRAM      :: Int64 -- ^ maximum bytes for all non-file values in the 'Request' body
                 , maxHeader   :: Int64 -- ^ maximum bytes of overhead for headers in @multipart/form-data@
                 }

-- | create a 'BodyPolicy' for use with decodeBody
defaultBodyPolicy :: FilePath -- ^ temporary directory for file uploads
                  -> Int64 -- ^ maximum bytes for files uploaded in this 'Request'
                  -> Int64 -- ^ maximum bytes for all non-file values in the 'Request' body
                  -> Int64 -- ^ maximum bytes of overhead for headers in @multipart/form-data@
                  -> BodyPolicy
defaultBodyPolicy tmpDir md mr mh =
    BodyPolicy { inputWorker = defaultInputIter defaultFileSaver tmpDir 0 0 0
               , maxDisk   = md
               , maxRAM    = mr
               , maxHeader = mh
               }

bodyInput :: (MonadIO m) => BodyPolicy -> Request -> m ([(String, Input)], Maybe String)
bodyInput _ req | (not (canHaveBody (rqMethod req))) || (not (isDecodable ctype)) =
    do _ <- liftIO $ tryPutMVar (rqInputsBody req) []
       return ([], Nothing)
    where
      ctype :: Maybe ContentType
      ctype = parseContentType . P.unpack =<< getHeader "content-type" req
      isDecodable :: Maybe ContentType -> Bool
      isDecodable Nothing                                                      = True -- assume it is application/x-www-form-urlencoded
      isDecodable (Just (ContentType "application" "x-www-form-urlencoded" _)) = True
      isDecodable (Just (ContentType "multipart" "form-data" _ps))             = True
      isDecodable (Just _)                                                     = False

bodyInput bodyPolicy req =
  liftIO $
    do let ctype = parseContentType . P.unpack =<< getHeader "content-type" req
       mbi <- tryTakeMVar (rqInputsBody req)
       case mbi of
         (Just bi) ->
             do putMVar (rqInputsBody req) bi
                return (bi, Nothing)
         Nothing ->
             do rqbody <- takeRequestBody req
                case rqbody of
                  Nothing          -> return ([], Just $ "bodyInput: Request body was already consumed.")
                  (Just (Body bs)) ->
                      do r@(inputs, _err) <- decodeBody bodyPolicy ctype bs
                         putMVar (rqInputsBody req) inputs
                         return r

-- | Decodes application\/x-www-form-urlencoded inputs.
-- TODO: should any of the [] be error conditions?
formDecode :: String -> [(String, Input)]
formDecode [] = []
formDecode qString =
    if null pairString then rest else
           (SURI.unEscapeQS name,simpleInput $ SURI.unEscapeQS val):rest
    where (pairString,qString')= split (=='&') qString
          (name,val)=split (=='=') pairString
          rest=if null qString' then [] else formDecode qString'

-- | Decodes application\/x-www-form-urlencoded inputs.
-- TODO: should any of the [] be error conditions?
formDecodeBS :: L.ByteString -> [(String, Input)]
formDecodeBS qString | L.null qString = []
formDecodeBS qString =
    if L.null pairString
       then rest            -- skip in case of consecutive ampersands "...&&..."
       else (SURI.unEscapeQS (L.unpack name), simpleInput $ SURI.unEscapeQS (L.unpack $ L.drop 1 val)) : rest
    where (pairString,qString') = L.break (== '&') qString
          (name,val) = L.break (== '=') pairString
          rest = formDecodeBS (L.drop 1 qString')

-- FIXME: is usend L.unpack really the right thing to do
decodeBody :: BodyPolicy
           -> Maybe ContentType
           -> L.ByteString
           -> IO ([(String,Input)], Maybe String)
decodeBody bp ctype inp
    = case ctype of
        Just (ContentType "application" "x-www-form-urlencoded" _) ->
            return decodedUrlEncodedForm
        Just (ContentType "multipart" "form-data" ps) ->
            multipartDecode ((inputWorker bp) (maxDisk bp) (maxRAM bp) (maxHeader bp)) ps inp
        Just ct ->
            return ([], Just $ "decodeBody: unsupported content-type: " ++ show ct) -- unknown content-type, the user will have to
                     -- deal with it by looking at the raw content
        -- No content-type given, assume x-www-form-urlencoded
        Nothing -> return decodedUrlEncodedForm
  where
     (upToMaxRAM,overMaxRAM) = L.splitAt (maxRAM bp) inp
     decodedUrlEncodedForm = (formDecodeBS upToMaxRAM,
                              if L.null overMaxRAM
                              then Nothing
                              else Just ("x-www-form-urlencoded content longer than BodyPolicy.maxRAM=" ++ show (maxRAM bp) ++ " bytes"))

-- | Decodes multipart\/form-data input.
multipartDecode :: InputWorker
                -> [(String,String)] -- ^ Content-type parameters
                -> L.ByteString      -- ^ Request body
                -> IO ([(String,Input)], Maybe String) -- ^ Input variables and values.
multipartDecode worker ps inp =
    case lookup "boundary" ps of
         Just b  -> multipartBody worker (L.pack b) inp
         Nothing -> return ([], Just $ "boundary not found in parameters: " ++ show ps)

-- | Get the path components from a String.
pathEls :: String -> [String]
pathEls = (drop 1) . map (U.toString . P.pack . SURI.unEscape) . splitList '/'

-- | Repeadly splits a list by the provided separator and collects the results
splitList :: Eq a => a -> [a] -> [[a]]
splitList _   [] = []
splitList sep list = h:splitList sep t
        where (h,t)=split (==sep) list

-- | Repeatedly splits a list and collects the results
splitListBy :: (a -> Bool) -> [a] -> [[a]]
splitListBy _ [] = []
splitListBy f list = h:splitListBy f t
        where (h,t)=split f list

-- | Split is like break, but the matching element is dropped.
split :: (a -> Bool) -> [a] -> ([a], [a])
split f s = (left,right)
        where
        (left,right')=break f s
        right = if null right' then [] else tail right'

