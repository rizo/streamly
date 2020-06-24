{-# LANGUAGE CPP                       #-}
{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MagicHash                 #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UnboxedTuples             #-}
{-# LANGUAGE FlexibleContexts          #-}

#include "inline.hs"

-- |
-- Module      : Streamly.Internal.Data.Prim.Pinned.Array.Types
-- Copyright   : (c) 2019 Composewell Technologies
--
-- License     : BSD3
-- Maintainer  : streamly@composewell.com
-- Stability   : experimental
-- Portability : GHC
--
module Streamly.Internal.Data.Prim.Pinned.Array.Types
    (
      Array (..)
    , unsafeFreeze
    , unsafeThaw
    , defaultChunkSize
    , empty

    -- * Construction
    , spliceTwo

    , fromList
    , fromListN
    , fromStreamDN
    , fromStreamD

    -- * Streams of arrays
    , fromStreamDArraysOf
    , FlattenState (..) -- for inspection testing
    , flattenArrays
    , flattenArraysRev
    , packArraysChunksOf
    , lpackArraysChunksOf
#if !defined(mingw32_HOST_OS)
--    , groupIOVecsOf
#endif
    , splitOn
    , breakOn

    -- * Elimination
    , unsafeIndex
    , byteLength
    , length

    , foldl'
    , foldr
    , foldr'
    , foldlM'
    , splitAt

    , toStreamD
    , toStreamDRev
    , toStreamK
    , toStreamKRev
    , toList
--    , toArrayMinChunk
    , writeN
    , write

    , unlines

    , toPtr
    , memcmp
    , memcpy
    , unsafeInlineIO

    , touchArray
    , withArrayAsPtr
    )
where

import Foreign.C.Types (CSize(..), CInt(..))
import Control.Monad (void)
import GHC.IO (IO(..))

import qualified Streamly.Internal.Data.Prim.Pinned.Mutable.Array.Types as MA

#include "prim-array-types.hs"

-------------------------------------------------------------------------------
-- Utility functions
-------------------------------------------------------------------------------

-- XXX It seems these are not being used anymore, should be removed, or moved
-- to the module where they are being used.

foreign import ccall unsafe "string.h memcpy" c_memcpy
    :: Ptr Word8 -> Ptr Word8 -> CSize -> IO (Ptr Word8)

-- XXX we are converting Int to CSize
memcpy :: Ptr Word8 -> Ptr Word8 -> Int -> IO ()
memcpy dst src len = void (c_memcpy dst src (fromIntegral len))

-- Check if this is safe
foreign import ccall unsafe "string.h memcmp" c_memcmp
    :: Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt

{-# INLINE memcmp #-}
memcmp :: Ptr Word8 -> Ptr Word8 -> Int -> IO Bool
memcmp p1 p2 len = do
    r <- c_memcmp p1 p2 (fromIntegral len)
    return $ r == 0

-------------------------------------------------------------------------------
-- Using as a Pointer
-------------------------------------------------------------------------------

-- Change name later.
{-# INLINE toPtr #-}
toPtr :: Array a -> Ptr a
toPtr (Array arr#) = Ptr (byteArrayContents# arr#)

{-# INLINE touchArray #-}
touchArray :: Array a -> IO ()
touchArray arr = IO $ \s -> case touch# arr s of s1 -> (# s1, () #)

{-# INLINE withArrayAsPtr #-}
withArrayAsPtr :: Array a -> (Ptr a -> IO b) -> IO b
withArrayAsPtr arr f = do
    r <- f (toPtr arr)
    touchArray arr
    return r
