-- | The event time stamp, for example @2026-10-05T12:00:00Z@. The functions
-- give the same results as 'formatTime' and 'parseTimeM' with the format of
-- 'timeFormat'. The usual case has a direct path, because the general
-- functions work on 'String' and dominate the cost of an event decode. Every
-- other case goes to the general functions.
module Akyuu.Sync.Stamp (formatStamp, parseStamp) where

import Akyuu.Memory (timeFormat)
import Data.Char (chr, isDigit, ord)
import Data.Time (UTCTime (UTCTime, utctDay, utctDayTime), defaultTimeLocale, formatTime, fromGregorianValid, parseTimeM, toGregorian)

formatStamp :: UTCTime -> String
formatStamp time
  | year >= 1000 && year <= 9999 && seconds >= 0 && seconds < 86400 =
      digits 4 (fromInteger year) <> "-" <> digits 2 month <> "-" <> digits 2 day <> "T" <> digits 2 (seconds `div` 3600) <> ":" <> digits 2 (seconds `div` 60 `mod` 60) <> ":" <> digits 2 (seconds `mod` 60) <> "Z"
  | otherwise = formatTime defaultTimeLocale timeFormat time
  where
    (year, month, day) = toGregorian (utctDay time)
    seconds = floor (utctDayTime time) :: Int
    digits :: Int -> Int -> String
    digits width value = [chr (ord '0' + value `div` (10 ^ place) `mod` 10) | place <- [width - 1, width - 2 .. 0]]

-- | Leading and trailing white space is permitted, as before.
parseStamp :: String -> Maybe UTCTime
parseStamp text = case text of
  [y1, y2, y3, y4, '-', m1, m2, '-', d1, d2, 'T', h1, h2, ':', n1, n2, ':', s1, s2, 'Z']
    | all isDigit [y1, y2, y3, y4, m1, m2, d1, d2, h1, h2, n1, n2, s1, s2],
      year >= 1000,
      hour < 24,
      minute < 60,
      second < 60,
      Just date <- fromGregorianValid (toInteger year) (number [m1, m2]) (number [d1, d2]) ->
        Just (UTCTime date (fromIntegral (hour * 3600 + minute * 60 + second)))
    where
      year = number [y1, y2, y3, y4]
      hour = number [h1, h2]
      minute = number [n1, n2]
      second = number [s1, s2]
  _ -> parseTimeM True defaultTimeLocale timeFormat text
  where
    number = foldl (\total char -> total * 10 + ord char - ord '0') 0
