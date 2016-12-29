{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module DB.PostgresBackend where

import Control.Monad (void)
import Control.Monad.Catch (catches, catch, throwM)
import Data.ByteString (ByteString)
import Data.String.Utils (replace)
import Database.PostgreSQL.Simple
import GHC.Int (Int64)
import System.IO.Error (IOError)

import qualified Exception.Handler as E
import Exception.Util (handles)

-- |Attempt to select from the "attribute" table in the Sparkive database.
--  If the selection fails, we say that the database does not exist or has
--  been partially deleted.
checkDBExists :: Connection -> IO (Either String Bool)
checkDBExists conn = do
    let q = fmap Right (query_ conn "SELECT * FROM attribute" :: IO [(Int, String)])
    --Unfortunately, I'm assuming that the above query is valid in all cases except those where the
    --table doesn't exist.
    eitherErrResults <- catches q [E.handleSQLError]
    --Need to make sure that the DB didn't shit the bed in some other way.
    checkForVeryBadThings <- catches q [ E.handleSQLResultError
                                   , E.handleSQLFormatError
                                   , E.handleSQLQueryError
                                   , E.handleErrorCall
                                   ]
    --if not bad things, continue as planned. If bad things, return Left with an error.
    return $ checkForVeryBadThings >> case eitherErrResults of
                Left  _ -> return False
                Right _ -> return True

-- |Given a function to process query results and the query itself,
--  return the processed results of the query. The function is given to
--  avoid incessant fmapping.
tryQuery :: (a -> b) -> IO a -> IO (Either String b)
tryQuery f q = catches (fmap (Right . f) q) $ E.handleErrorCall : E.sqlErrorHandlers

-- TODO Incomplete and unsafe
-- |Parse the "db/create.sql" file, and use it to create the necessary tables
--  for a Sparkive installation.
createDB :: String -> Connection -> IO (Either String ())
createDB user conn = do
    let filepath = "db/create.sql"
    let fileErrStr = "Could not open file \"" ++ filepath ++
                    "\". Please check that the file exists and is readable in\
                    \ your Sparkive installation."
    (f :: String) <- catch (readFile filepath) (\(x :: IOError) ->
                          throwM $ E.ReadFileException fileErrStr
                                               )
    putStrLn "still here."

    let (q :: Query) = read . show $ replace "%user%" user f
    tryQuery (const ()) $ execute_ conn q

insertUser :: String -> ByteString -> Connection -> IO (Either String ())
insertUser username pass conn =
    tryQuery (const ()) $
            execute conn "INSERT INTO sparkive_user (username, pass) VALUES (?,?)" (username, pass)

getPassHash :: String -> Connection -> IO (Either String ByteString)
getPassHash username conn = do
    res <- tryQuery (map fromOnly)
                    (query conn "SELECT pass FROM sparkive_user WHERE username = ?" 
                        (Only username) :: IO [Only ByteString]
                    )
    return $ case res of
                Left err -> Left err
                Right bss -> if length bss /= 1
                             then Left errStr
                             else Right $ head bss
 where errStr = "User " ++ username ++ "'s passhash count does not equal 1."