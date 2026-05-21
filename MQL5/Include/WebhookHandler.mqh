//+------------------------------------------------------------------+
//|                                             WebhookHandler.mqh   |
//|                        Handles webhook signal reception          |
//+------------------------------------------------------------------+
#property copyright "DevyyTrades"
#property strict

#include <WinUser32.mqh>
#include <WinInet.mqh>

//--- Webhook data structure
struct WebhookData
{
   string               indicator;    // "Wickless", "FVG", "News"
   string               signalType;   // "NOWICK_BULLISH", "FVG_BEARISH_4H", etc.
   string               symbol;       // "EURUSD", "XAUUSD", etc.
   double               price;        // Signal price
   double               high;         // Candle high
   double               low;          // Candle low
   double               swingHigh;    // Recent swing high
   double               swingLow;     // Recent swing low
   double               fvgTop;       // FVG top level
   double               fvgBottom;    // FVG bottom level
   string               timeframe;    // "15M", "4H", "DAILY"
   datetime             newsTime;     // News event time
   string               newsImpact;   // "HIGH", "MEDIUM", "LOW"
   string               rawData;      // Raw JSON data
};

//+------------------------------------------------------------------+
//| Webhook handler class                                            |
//+------------------------------------------------------------------+
class CWebhookHandler
{
private:
   int                  m_socket;
   string               m_port;
   string               m_authToken;
   string               m_buffer;
   string               m_signalFile;

   // Parse JSON webhook data
   bool                 ParseWebhookData(string json, WebhookData &data);
   string               GetJsonValue(string json, string key);
   double               GetJsonDouble(string json, string key);

public:
                        CWebhookHandler();
                       ~CWebhookHandler();

   // Initialize webhook listener
   bool                 Init(string port, string authToken = "");

   // Check for new signals
   bool                 CheckForSignal(WebhookData &signal);

   // File-based signal reading (fallback)
   bool                 ReadSignalFromFile(WebhookData &signal);
   void                 ClearSignalFile();

   // Setters
   void                 SetAuthToken(string token) { m_authToken = token; }
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CWebhookHandler::CWebhookHandler()
{
   m_socket = INVALID_HANDLE;
   m_port = "8080";
   m_authToken = "";
   m_buffer = "";
   m_signalFile = "DevyyTrades_Signals.json";
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CWebhookHandler::~CWebhookHandler()
{
   // Cleanup if needed
}

//+------------------------------------------------------------------+
//| Initialize webhook handler                                         |
//+------------------------------------------------------------------+
bool CWebhookHandler::Init(string port, string authToken)
{
   m_port = port;
   m_authToken = authToken;

   // Create the signals file if it doesn't exist
   string filename = "MQL5\\Files\\" + m_signalFile;
   int handle = FileOpen(m_signalFile, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileClose(handle);
   }

   Print("Webhook handler initialized");
   Print("Signal file location: ", filename);
   Print("Expected webhook format: JSON with indicator, symbol, signalType, etc.");

   return true;
}

//+------------------------------------------------------------------+
//| Check for new signals (file-based approach)                        |
//+------------------------------------------------------------------+
bool CWebhookHandler::CheckForSignal(WebhookData &signal)
{
   // For MT5, we use a file-based approach where the Python webhook server
   // writes signals to a JSON file that this EA reads

   return ReadSignalFromFile(signal);
}

//+------------------------------------------------------------------+
//| Read signal from file                                              |
//+------------------------------------------------------------------+
bool CWebhookHandler::ReadSignalFromFile(WebhookData &signal)
{
   string filepath = m_signalFile;

   // Check if file exists
   if(!FileIsExist(filepath, FILE_COMMON))
   {
      return false;
   }

   int handle = FileOpen(filepath, FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      return false;
   }

   // Read file content
   string content = "";
   while(!FileIsEnding(handle))
   {
      content += FileReadString(handle);
   }
   FileClose(handle);

   // Check if empty
   if(StringLen(content) < 10)
   {
      return false;
   }

   // Parse the JSON
   if(!ParseWebhookData(content, signal))
   {
      Print("Failed to parse webhook data");
      ClearSignalFile();
      return false;
   }

   // Clear file after reading
   ClearSignalFile();

   return true;
}

//+------------------------------------------------------------------+
//| Clear signal file after processing                                 |
//+------------------------------------------------------------------+
void CWebhookHandler::ClearSignalFile()
{
   int handle = FileOpen(m_signalFile, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, "{}");
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| Parse webhook JSON data                                            |
//+------------------------------------------------------------------+
bool CWebhookHandler::ParseWebhookData(string json, WebhookData &data)
{
   // Clean up the JSON string
   StringReplace(json, "\\\"", "\"");
   StringReplace(json, "\r\n", "");
   StringReplace(json, "\n", "");

   data.rawData = json;

   // Extract indicator type
   data.indicator = GetJsonValue(json, "indicator");
   if(data.indicator == "")
   {
      Print("No indicator field found in webhook");
      return false;
   }

   // Extract common fields
   data.signalType = GetJsonValue(json, "signalType");
   data.symbol = GetJsonValue(json, "symbol");
   data.timeframe = GetJsonValue(json, "timeframe");
   data.newsImpact = GetJsonValue(json, "newsImpact");

   // Extract numeric values
   data.price = GetJsonDouble(json, "price");
   data.high = GetJsonDouble(json, "high");
   data.low = GetJsonDouble(json, "low");
   data.swingHigh = GetJsonDouble(json, "swingHigh");
   data.swingLow = GetJsonDouble(json, "swingLow");
   data.fvgTop = GetJsonDouble(json, "fvgTop");
   data.fvgBottom = GetJsonDouble(json, "fvgBottom");

   // Extract news time
   string newsTimeStr = GetJsonValue(json, "newsTime");
   if(newsTimeStr != "")
   {
      // Parse ISO 8601 format: 2024-01-15T14:30:00Z
      data.newsTime = StringToTime(newsTimeStr);
   }

   // Validate required fields
   if(data.symbol == "")
   {
      Print("No symbol in webhook data");
      return false;
   }

   Print("Parsed webhook - Indicator: ", data.indicator,
         " Symbol: ", data.symbol,
         " Type: ", data.signalType);

   return true;
}

//+------------------------------------------------------------------+
//| Extract string value from JSON                                     |
//+------------------------------------------------------------------+
string CWebhookHandler::GetJsonValue(string json, string key)
{
   string searchKey = "\"" + key + "\":";
   int keyPos = StringFind(json, searchKey);

   if(keyPos == -1)
      return "";

   int valueStart = keyPos + StringLen(searchKey);

   // Skip whitespace
   while(valueStart < StringLen(json) &&
code
codelanguage="mql5"
         (json[valueStart] == ' ' || json[valueStart] == '\t'))
      valueStart++;

   // Check if value is quoted
   bool isQuoted = (json[valueStart] == '"');

   if(isQuoted)
   {
      valueStart++; // Skip opening quote
      int valueEnd = StringFind(json, "\"", valueStart);
      if(valueEnd == -1)
         return "";

      return StringSubstr(json, valueStart, valueEnd - valueStart);
   }
   else
   {
      // Unquoted value (number, boolean, null)
      int valueEnd = StringFind(json, ",", valueStart);
      if(valueEnd == -1)
         valueEnd = StringFind(json, "}", valueStart);
      if(valueEnd == -1)
         return "";

      return StringSubstr(json, valueStart, valueEnd - valueStart);
   }
}

//+------------------------------------------------------------------+
//| Extract double value from JSON                                     |
//+------------------------------------------------------------------+
double CWebhookHandler::GetJsonDouble(string json, string key)
{
   string value = GetJsonValue(json, key);
   if(value == "")
      return 0.0;

   return StringToDouble(value);
}
//+------------------------------------------------------------------+
