USE Winlogon

DECLARE @bSendmail bit
SET @bSendmail = 1

DECLARE @SCARD_W_WRONG_CHV bigint
SET @SCARD_W_WRONG_CHV = -2146434965

DECLARE @stMessageBody AS nvarchar(4000), @stMessageBody1 nvarchar(4000)
SET @stMessageBody = ""
SET @stMessageBody1 = ""

DECLARE @crlf nvarchar(2)
SET @crlf = CHAR(13) + CHAR(10)

DECLARE @Buffer nvarchar(256), @Number nvarchar(5), @Percent nvarchar(3)

DECLARE @Checkdate datetime
SET @Checkdate = DATEADD(day, -8, GETDATE())
--SET @Checkdate = DATEADD(day, -2, GETDATE())

SELECT CARD
FROM AuthMonitor
WHERE TIMESTAMP > @Checkdate
AND CARD <> ""

DECLARE @NumCardAuth int
SET @NumCardAuth = @@ROWCOUNT

--
-- Get number of reader / card operations
--
CREATE TABLE #CardReaderAuth
(
    CARD nvarchar(64),
    READER nvarchar(64),
    FAILURE int,
    NUMBER int
)

DECLARE @iCardHandle int, @stCard nvarchar(64)
SET @iCardHandle = 0
EXEC #GetCard @stCard OUTPUT, @iCardHandle OUTPUT

WHILE @stCard <> ""
BEGIN

    DECLARE @iReaderHandle int, @stReader nvarchar(64)
    SET @iReaderHandle = 0
    EXEC #GetReader @stReader OUTPUT, @iReaderHandle OUTPUT

    WHILE @stReader <> ""
    BEGIN
        
	-- Get number of total operations
        SELECT CARD, READER
        FROM AuthMonitor
        WHERE TIMESTAMP > @Checkdate
        AND CARD = @stCard
        AND READER LIKE @stReader + "%"

    	INSERT INTO #CardReaderAuth VALUES (@stCard, @stReader, 0, @@ROWCOUNT)

	-- Get number of failures
        SELECT CARD, READER
        FROM AuthMonitor
        WHERE TIMESTAMP > @Checkdate
        AND CARD = @stCard
        AND READER LIKE @stReader + "%"
	AND STATUS <> 0 
	AND STATUS <> @SCARD_W_WRONG_CHV

    	INSERT INTO #CardReaderAuth VALUES (@stCard, @stReader, 1, @@ROWCOUNT)
        EXEC #GetReader @stReader OUTPUT, @iReaderHandle OUTPUT
    END

    EXEC #GetCard @stCard OUTPUT, @iCardHandle OUTPUT
END

--
-- Create the message for Card / Reader authentications and failures
--
DECLARE CardReaderCursor CURSOR FOR
    SELECT CARD, READER, FAILURE, NUMBER 
    FROM #CardReaderAuth
    ORDER BY READER ASC, CARD ASC

DECLARE @iNumPerCardReaderAuth int, @NumPerCardReaderFailures int
SET @iNumPerCardReaderAuth = -1
SET @NumPerCardReaderFailures = -1

DECLARE @LastReader nvarchar(64)
SET @LastReader = ""

DECLARE @NumAuth int, @Failure int

OPEN CardReaderCursor
FETCH NEXT FROM CardReaderCursor
INTO @stCard, @stReader, @Failure, @NumAuth

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @Failure = 0
        SET @iNumPerCardReaderAuth = @NumAuth
    ELSE
        SET @NumPerCardReaderFailures = @NumAuth

    IF @iNumPerCardReaderAuth <> -1 AND @NumPerCardReaderFailures <> -1
    BEGIN

        DECLARE TimerCursor CURSOR FOR
            SELECT STOPWATCH, STATUS
            FROM AuthMonitor
            WHERE TIMESTAMP > @Checkdate
            AND CARD = @stCard
            AND READER LIKE @stReader + "%"
            AND STATUS <> @SCARD_W_WRONG_CHV

        DECLARE @iStopwatch int, @iStatus int        

        OPEN TimerCursor
        FETCH NEXT FROM TimerCursor
        INTO @iStopwatch, @iStatus
 
        DECLARE @iAverageSuccess int, @iNumSuccess int
        DECLARE @iAverageFailure int, @iNumFailure int
        SET @iAverageSuccess = 0
        SET @iNumSuccess = 0
        SET @iAverageFailure = 0
        SET @iNumFailure = 0

        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @iStatus = 0
            BEGIN
                SET @iAverageSuccess = @iAverageSuccess + @iStopwatch
                SET @iNumSuccess = @iNumSuccess + 1
            END
            ELSE
            BEGIN
                SET @iAverageFailure = @iAverageFailure + @iStopwatch
                SET @iNumFailure = @iNumFailure + 1
            END

            FETCH NEXT FROM TimerCursor
            INTO @iStopwatch, @iStatus
        END

        CLOSE TimerCursor
        DEALLOCATE TimerCursor

        IF @iNumPerCardReaderAuth <> 0
        BEGIN

            IF @stReader <> @LastReader
            BEGIN
               IF LEN(@stMessageBody) > 3000
               BEGIN
                  SET @stMessageBody1 = @stMessageBody
                  SET @stMessageBody = ""
                  SET @LastReader = ""
               END

               IF @LastReader <> ""
                   SET @stMessageBody = @stMessageBody + @crlf

               EXEC master.dbo.xp_sprintf @Buffer OUTPUT, "%-34s        Total |   Failures |   Times", @stReader
               SET @stMessageBody = @stMessageBody + @Buffer + @crlf +
                                    REPLICATE("-", 70) + @crlf
            END
            SET @LastReader = @stReader 

            -- Card / reader total
            SET @Number = CAST(@iNumPerCardReaderAuth AS nvarchar(5))
            SET @Percent = CAST(@iNumPerCardReaderAuth * 100 / @NumCardAuth AS nvarchar(3))
            EXEC master.dbo.xp_sprintf @Buffer OUTPUT, "   %-34s%5s%4s%%", @stCard, @Number, @Percent
            SET @stMessageBody = @stMessageBody + @Buffer

            -- Card / reader failures
            SET @Number = CAST(@NumPerCardReaderFailures AS nvarchar(5))
            SET @Percent = CAST(@NumPerCardReaderFailures * 100 / @iNumPerCardReaderAuth AS nvarchar(3))
            EXEC master.dbo.xp_sprintf @Buffer OUTPUT, " | %5s%4s%%", @Number, @Percent
            SET @stMessageBody = @stMessageBody + @Buffer

            -- Times
            DECLARE @stAverageSuccess nvarchar(5), @stAverageFailure nvarchar(5)

            IF @iNumSuccess <> 0
                SET @stAverageSuccess = CAST(@iAverageSuccess / @iNumSuccess / 1000 AS nvarchar(5))
            ELSE 
                SET @stAverageSuccess = "-"

            IF @iNumFailure <> 0
                SET @stAverageFailure = CAST(@iAverageFailure / @iNumFailure / 1000 AS nvarchar(5))        
            ELSE
                SET @stAverageFailure = "-"

            EXEC master.dbo.xp_sprintf @Buffer OUTPUT, " | %3s/%3s", @stAverageSuccess, @stAverageFailure
            SET @stMessageBody = @stMessageBody + @Buffer + @crlf
        END

        SET @iNumPerCardReaderAuth = -1
        SET @NumPerCardReaderFailures = -1
    END

    FETCH NEXT FROM CardReaderCursor
    INTO @stCard, @stReader, @Failure, @NumAuth
END

CLOSE CardReaderCursor
DEALLOCATE CardReaderCursor

IF @stMessageBody1 = ""
BEGIN
    SET @stMessageBody1 = @stMessageBody
    SET @stMessageBody = ""
END

IF @bSendmail <> 0
BEGIN
    EXEC master.dbo.xp_sendmail 
         @recipients = 'smcaft', 
         @message =  @stMessageBody1,
         @subject = 'Smart card self host report - reader/card matrix'

    IF @stMessageBody <> ""
        EXEC master.dbo.xp_sendmail 
             @recipients = 'smcaft', 
             @message =  @stMessageBody,
             @subject = 'Smart card self host report - reader/card matrix II'
END
ELSE
BEGIN
    PRINT @stMessageBody1 + @crlf
    PRINT @stMessageBody
END
