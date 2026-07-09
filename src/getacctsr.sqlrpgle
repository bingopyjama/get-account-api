      **FREE
      //********************************************************************
      // Program: GETACCTSR - Get Accounts REST API (ILE RPG)
      // Description: Native ILE RPG REST API to query BMF40P by client
      // Type: CGI program for IBM HTTP Server
      // URL: http://your-ibm-i/cgi-bin/getacctsr/client/12345
      //********************************************************************

       ctl-opt dftactgrp(*no) actgrp('QILE') bnddir('HTTPBNDDIR');

       // Global variables
        dcl-s requestMethod char(10);
        dcl-s pathInfo char(256);
        dcl-s queryString char(1024);
        dcl-s clientNumber char(10);
        dcl-s responseJson varchar(32000);
        dcl-s httpStatus int(10);
        dcl-s contentType char(50);
        dcl-s errorOccurred ind inz(*off);

       dcl-pr GetEnvironmentVar pointer extproc('getenv');
         varName pointer value options(*string);
       end-pr;

       dcl-pr WriteStdout extproc('QtmhWrStout');
         data pointer value;
         //szHtml char(65535) Const OPTIONS(*VARSIZE);
         dataLen int(10) const;
         errorCode likeds(qusec);
       end-pr;

     Dlinefeed         C                   x'15'

       dcl-ds QUSEC qualified;
         QUSBPRV  int(10) inz(16);     // Bytes Provided
         QUSBAVL  int(10);             // Bytes Available
         QUSEI    char(7);               // Exception Id
         QUSERVED char(1);            // Reserved
       end-ds;

       //********************************************************************
       // Main Procedure
       //********************************************************************


        // Ensure we always send headers, even if error occurs
        monitor;
          // Get CGI environment variables
          requestMethod = GetEnvVar('REQUEST_METHOD');
          pathInfo = GetEnvVar('PATH_INFO');
          queryString = GetEnvVar('QUERY_STRING');

          // Set default response
          httpStatus = 200;
          contentType = 'application/json; charset=utf-8';

          // Initialize response in case of early error
          responseJson = '{"error":"Unknown error"}';

          // Route the request
          if requestMethod = 'GET' or requestMethod = *blanks;
            HandleGetRequest();
          else;
            httpStatus = 405;  // Method Not Allowed
            responseJson = '{"error":"Method Not Allowed",' +
                  '"message":"Only GET requests are supported"}';
          endif;

        on-error;
          // Catch any unhandled errors
          httpStatus = 500;
          responseJson = '{"error":"Internal Server Error",' +
               '"message":"An unexpected error occurred in main"}';
          errorOccurred = *on;
        endmon;

        // Always send HTTP response
        SendHttpResponse();

        return;

       //********************************************************************
       // Handle GET Request
       //********************************************************************
       dcl-proc HandleGetRequest;

        dcl-s pathParts varchar(256) dim(10);
        dcl-s partCount int(10);

        // Parse path: /client/12345
        partCount = ParsePath(pathInfo: pathParts);

        // Check for health endpoint
        if pathInfo = '/health' or pathInfo = '/';
          responseJson = '{"status":"healthy",' +
                        '"service":"IBIS Account API",' +
                        '"version":"1.0.0",' +
                        '"technology":"ILE RPG REST"}';
          return;
        endif;

        // Check for /client/{clientNumber} pattern
        if partCount >= 2 and pathParts(1) = 'client';
          clientNumber = %trim(pathParts(2));
          GetAccountsByClient();
        else;
          httpStatus = 404;
          responseJson = '{"error":"Not Found",' +
              '"message":"Invalid endpoint. Use /client/{clientNumber}"}';
        endif;

       end-proc;

       //********************************************************************
       // Get Accounts by Client Number
       //********************************************************************
       dcl-proc GetAccountsByClient;

        dcl-s accountCount int(10);

        // Validate client number
        if clientNumber = *blanks;
          httpStatus = 400;
          responseJson = '{"error":"Bad Request",' +
                        '"message":"Client number is required"}';
          return;
        endif;

        // Check if client exists
        exec sql
          SELECT COUNT(*)
          INTO :accountCount
          FROM BMF40P
          WHERE B40CLT = :clientNumber;

        if sqlcode <> 0;
          httpStatus = 500;
          responseJson = '{"error":"Database Error",' +
                        '"message":"Failed to query accounts",' +
                        '"sqlcode":' + %char(sqlcode) + '}';
          return;
        endif;

        if accountCount = 0;
          httpStatus = 404;
          responseJson = '{"error":"Not Found",' +
                        '"message":"No accounts found for client ' +
                        %trim(clientNumber) + '"}';
          return;
        endif;

        // Build JSON response
        BuildJsonResponse();

       end-proc;

       //********************************************************************
       // Build JSON Response from Database
       //********************************************************************
       dcl-proc BuildJsonResponse;

        exec sql
          select json_object(
           'success' value 'true',
           'CLIENT_NUMBER' value b00clt,
           'CLIENT_NAME' value trim(b00cna),
           'ACCOUNT_COUNT' value count(*),
           'accounts' : json_arrayagg(
             json_object('ACCOUNT_NUMBER' value b40acc,
                         'CURRENCY' value b40csn,
                         'ACCOUNT_TITLE' value trim(b40atl),
                         'ACCOUNT_DESCRIPTION' value trim(b40ads),
                         'STATUS' value b40sts,
                         'OPEN_DATE' value b40opd,
                         'CLOSE_DATE' value b40cld)
           ),
           'timestamp' value current timestamp
         )
         into :responseJson
         from bmf00p, bmf40p
         where b00clt = b40clt and b00clt = :clientNumber
         group by b00clt, b00cna;

       end-proc;

       //********************************************************************
       // Send HTTP Response
       //********************************************************************
       dcl-proc SendHttpResponse;

        dcl-s header varchar(1000);
        dcl-s headerLn int(10);
        dcl-s statusText char(20);
        dcl-s jsonLen int(10);
        dcl-s utfdata varchar(200000) ccsid(*utf8);
        dcl-s payload varchar(200000) ccsid(*utf8);

        dcl-c CRLF x'0d25';

        // Ensure we have a response
        if responseJson = '';
          responseJson = '{"error":"Empty response"}';
        endif;

        // Determine status text
        select;
          when httpStatus = 200;
            statusText = 'OK';
          when httpStatus = 400;
            statusText = 'Bad Request';
          when httpStatus = 404;
            statusText = 'Not Found';
          when httpStatus = 405;
            statusText = 'Method Not Allowed';
          when httpStatus = 500;
            statusText = 'Internal Server Error';
          other;
            statusText = 'Unknown';
        endsl;

        monitor;
          // Convert JSON body from EBCDIC to UTF-8
          utfdata = responseJson;  // Automatic CCSID conversion
          //utfdata = '{"make":"Toyota"}';
          jsonLen = %len(%trimr(utfdata));

          // Build HTTP headers with correct Content-Length
          header = 'Status: ' + %char(httpStatus) + ' ' +
                                %trim(statusText) + crlf +
                   'Content-Type: ' + %trim(contentType) + crlf +
                   'Content-Length: ' + %char(jsonLen) + crlf +
                   crlf;  // Empty line to end headers

          payload = header + utfdata;
          //WriteStdout( %addr(payload:*data) : %len(payload) : QUSEC );

          // Write headers (EBCDIC - HTTP server will handle)
          WriteStdout( %addr(header:*data) : %len(header) : QUSEC );


          // Write JSON body (UTF-8)
          WriteStdout( %addr(utfdata:*data) : %len(utfdata) : QUSEC );
        on-error;
          // If write fails, try to write a minimal error response
          header = 'Status: 500 Internal Server Error' + crlf +
                   'Content-Type: text/plain' + crlf + crlf +
                   'Error writing response';
          headerLn = %len(%trimr(header));
          WriteStdout( %addr(header:*data) : %len(header) : QUSEC );
        endmon;

       end-proc;

       //********************************************************************
       // Helper: Get Environment Variable
       //********************************************************************
       dcl-proc GetEnvVar;
        dcl-pi *n char(1024);
          varName char(50) const;
        end-pi;

        dcl-s result char(1024);
        dcl-s ptr pointer;

        ptr = GetEnvironmentVar(%trim(varName));

        if ptr <> *null;
          result = %str(ptr);
        else;
          result = '';
        endif;

        return result;
       end-proc;

       //********************************************************************
       // Helper: Parse URL Path
       //********************************************************************
       dcl-proc ParsePath;
        dcl-pi *n int(10);
          path char(256) const;
          parts varchar(256) dim(10);
        end-pi;

        dcl-s count int(10);
        dcl-s pos int(10);
        dcl-s startPos int(10);
        dcl-s pathTrim varchar(256);

        count = 0;
        pathTrim = %trim(path);

        // Remove leading slash
        if %subst(pathTrim:1:1) = '/';
          pathTrim = %subst(pathTrim:2);
        endif;

        // Split by slash
        dow pathTrim <> '';
          pos = %scan('/': pathTrim);

          if pos > 0;
            count += 1;
            parts(count) = %subst(pathTrim:1:pos-1);
            pathTrim = %subst(pathTrim:pos+1);
          else;
            count += 1;
            parts(count) = pathTrim;
            pathTrim = '';
          endif;
        enddo;

        return count;
       end-proc;

       //********************************************************************
       // Helper: Escape JSON special characters
       //********************************************************************
       dcl-proc EscapeJson;
        dcl-pi *n varchar(1000);
          input varchar(1000) const;
        end-pi;

        dcl-s output varchar(1000);
        dcl-s i int(10);
        dcl-s char char(1);

        output = '';

        for i = 1 to %len(input);
          char = %subst(input:i:1);

          select;
            when char = '"';
              output += '\"';
            when char = '\';
              output += '\\';
            when char = x'0D';  // CR
              output += '\r';
            when char = x'25';  // LF
              output += '\n';
            other;
              output += char;
          endsl;
        endfor;

        return output;
       end-proc;
