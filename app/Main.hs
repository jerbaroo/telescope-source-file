{-# OPTIONS_GHC -fno-warn-missing-fields #-}

module Main where

import           Telescope.Monad        (runScope)
import           Telescope.Operations   (viewAll)
import           Telescope.Source.File  (fileConfig)
import           Telescope.TutorialCode (User (..), example)

main :: IO ()
main = do
  config <- fileConfig "Tutorial"
  runScope config example
  print =<< runScope config (viewAll User{})
