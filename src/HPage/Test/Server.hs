
module HPage.Test.Server where

import Data.Char
import GHC.IOBase
import Control.Monad.Error
import Test.QuickCheck
import Test.QuickCheck.Batch
import qualified HPage.Control as HP hiding (HPage)
import qualified HPage.Server as HPS
import qualified Language.Haskell.Interpreter as Hint
import qualified Language.Haskell.Interpreter.Server as HS

instance Arbitrary Char where
    arbitrary = elements (['A'..'Z'] ++ ['a' .. 'z'] ++ " ~!@#$%^&*()")
    coarbitrary c = variant (ord c `rem` 16)

options :: TestOptions
options = TestOptions
      { no_of_tests         = 200
      , length_of_tests     = 1
      , debug_tests         = False }

main :: IO ()
main =
    do
        hps <- HPS.start
        hs <- HS.start
        runTests "HPage Server vs. Hint Server" options
                 [  run $ prop_fail hps hs
                 ,  run $ prop_same_response hps hs
                 ,  run $ prop_load_module hps hs
                 ,  run $ prop_reload_modules hps hs
                 ]

prop_same_response :: HPS.ServerHandle -> HS.ServerHandle -> String -> Bool
prop_same_response hps hs txt =
    unsafePerformIO $ do
                        let expr = "length \"" ++ txt ++ "\"" 
                        hpsr <- HPS.runIn hps $ HP.setText expr >> HP.eval
                        Right hsr <- HS.runIn hs $ Hint.eval expr
                        return $ hpsr == hsr

prop_fail :: HPS.ServerHandle -> HS.ServerHandle -> String -> Bool
prop_fail hps hs txt =
    unsafePerformIO $ do
                        let expr = "lenggth \"" ++ txt ++ "\""
                        Left hpsr <- HPS.runIn hps $ HP.setText expr >> try HP.eval
                        Left hsr <- HS.runIn hs $ Hint.eval expr
                        return $ "user error (" ++ show hsr ++ ")" == show hpsr
    where try a = (a >>= return . Right) `catchError` (return . Left)
    
prop_load_module :: HPS.ServerHandle -> HS.ServerHandle -> String -> Bool
prop_load_module hps hs txt =
    unsafePerformIO $ do
                        let expr = "test = length \"" ++ txt ++ "\"" 
                        hpsr <- HPS.runIn hps $ do
                                                    HP.setText expr
                                                    HP.savePage "../documents/test.hs"
                                                    HP.setText "test"
                                                    HP.loadModule "../documents/test.hs"
                                                    HP.eval
                        Right hsr <- HS.runIn hs $ Hint.eval expr
                        return $ hpsr == hsr

prop_reload_modules :: HPS.ServerHandle -> HS.ServerHandle -> String -> Bool
prop_reload_modules hps hs txt =
    unsafePerformIO $ do
                        let expr = "test = show \"" ++ txt ++ "\"" 
                        hpsr <- HPS.runIn hps $ do
                                                    HP.setText expr
                                                    HP.savePage "../documents/test.hs"
                                                    HP.setText "test"
                                                    HP.loadModule "../documents/test.hs"
                                                    HP.reloadModules
                                                    HP.eval
                        Right hsr <- HS.runIn hs $ Hint.eval expr
                        return $ hpsr == hsr