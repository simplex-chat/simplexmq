{-# LANGUAGE OverloadedStrings #-}

module Main where

import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = "5223",
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6,
      -- TODO these keys should be loaded from files, not set in the code
      serverKeyPair =
        ( "256,wgJfm+EgMI3MeGdZlNs+KEoMlO0bpvZ2sa7bK4zWGtWGWXoCq1m89gaMk+f+HZavNJbJmflqrviBAoCFtDrA5+xC4+mwGlU6mLWiWtpvxgRBtNBsuHg3l+oJv0giFNCxoscne3P6n4kaCQEbA1T6KdrsdvxcaqyqzbpI7SozLIzhy45gsVywJfzpu6GYHlYNizdBJtoX2r66v6jDQFX7/MVDG4Z84RRa8PzjzT0wXSY+nirwIy5uwD0V5jrwaB0S5re6UnL7aLp51zHLUHPI/C9okBIkjY9kyQg3mAYXOPxb0OlGf3ENWnVdPKG6WqYnC3SBMIEVd4rqqxoH4myTgQ==,DHXxHfufuxfbuReISV9tCNttWXm/EVXTTN//hHkW/1wPLppbpY6aOqW+SZWwGCodIdGvdPSmaY9W8kfftWQY9xCOOcpkrzZwYHppT995xBIoB30vXG01dyruebFr3HjurT+uUbRGnxNYGwZg3AjkcyQtMKmq1pANvOGsOUgeDiU=",
          "256,wgJfm+EgMI3MeGdZlNs+KEoMlO0bpvZ2sa7bK4zWGtWGWXoCq1m89gaMk+f+HZavNJbJmflqrviBAoCFtDrA5+xC4+mwGlU6mLWiWtpvxgRBtNBsuHg3l+oJv0giFNCxoscne3P6n4kaCQEbA1T6KdrsdvxcaqyqzbpI7SozLIzhy45gsVywJfzpu6GYHlYNizdBJtoX2r66v6jDQFX7/MVDG4Z84RRa8PzjzT0wXSY+nirwIy5uwD0V5jrwaB0S5re6UnL7aLp51zHLUHPI/C9okBIkjY9kyQg3mAYXOPxb0OlGf3ENWnVdPKG6WqYnC3SBMIEVd4rqqxoH4myTgQ==,PC6r+lZm5vyVpOl6dS9SXv09iE1PZoav6yeUbqsK+FScwHiOMEOkTY2mUyTHZ99nA4l7grAo4RPS6UOQS07QtgD2siZyj6F6Z3qAiBGesiG3+tb59pQ/prhs+5Q7RBlRMulz5KEwFINUb4Wy9ft4oIL/JJT9iSnYtTuGGirUEjB6YGzLKQeTyhkWA0iN89C5Vx6drB/pHyu3Mu+uc0Rax0UPD47gsNmxPNWUM6xLlkpNAWnSOHcSJZ3SN4QDLLCeBfqkgDLYkE3vbwvz8drt+H2eLi8OzFErEdkkrXg/0VwNjfhpBTt8D4TX00I7XsVksh3b2BRHzLfHTbLGdExLLQ=="
        )
    }

-- public key hash:
-- "8Cvd+AYVxLpSsB/glEhVxkKuEzMNBFdAL5yr7p9DGGk="

main :: IO ()
main = do
  putStrLn $ "Listening on port " ++ tcpPort cfg
  runSMPServer cfg
