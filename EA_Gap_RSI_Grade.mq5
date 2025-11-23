//+------------------------------------------------------------------+
//|                                       EA_Gap_RSI_Grade.mq5       |
//| Estratégia: Gaps + ATR + RSI + Grade de Preço Médio              |
//| Plataforma: MetaTrader 5 (MQL5)                                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

//==================================================================
// 1. PARÂMETROS DO PAINEL (INTERFACE DO USUÁRIO)
//==================================================================

// --- BLOCO RSI ---
input int    RSI_Period           = 14;     // Período do RSI
input double RSI_Overbought       = 70.0;   // Nível de sobrecompra (RSI) para VENDAS
input double RSI_Oversold         = 30.0;   // Nível de sobrevenda (RSI) para COMPRAS

// --- BLOCO ATR E GAPS ---
input int    ATR_Period           = 14;     // Período do ATR (mede volatilidade)
input double Gap_Size_Multiplier  = 1.5;    // Fator x ATR para considerar um gap "grande"

// --- BLOCO GRADE DE PREÇO MÉDIO ---
input double Grid_Step_Pips       = 300.0;  // Distância em pips entre níveis da grade
input int    Max_Grid_Levels      = 5;      // Número máximo de ordens na grade

// --- BLOCO RISCO E LOTE ---
input double Takeprofit_Mean_Pips = 150.0;  // Lucro em pips acima/abaixo do preço médio
input double Lot_Size             = 0.01;   // Lote de cada ordem da grade
input double Stop_Loss_Pips       = 50.0;   // Stop Loss em pips (0 = sem SL)

// --- BLOCO EXECUÇÃO / IDENTIFICAÇÃO ---
input ulong  MagicNumber          = 20251201; // Identificador das ordens do EA
input int    Slippage_Points      = 20;       // Máximo de desvio (slippage) em pontos

//==================================================================
// 2. VARIÁVEIS GLOBAIS
//==================================================================

CTrade trade;          // Objeto padrão para abrir/fechar ordens

// Handles dos indicadores
int    g_handleRSI = INVALID_HANDLE;
int    g_handleATR = INVALID_HANDLE;

// Tamanho de 1 pip em preço (ajusta para 3/5 dígitos)
double g_pipSize = 0.0;

// Controle da barra atual (para saber quando nasceu candle novo)
datetime g_lastBarTime  = 0;
double   g_lastBarClose = 0.0;

// Direção do gap detectado
enum GapDirection
  {
   GAP_NONE = 0,
   GAP_UP   = 1,   // Gap de alta → possível VENDA
   GAP_DOWN = -1   // Gap de baixa → possível COMPRA
  };

GapDirection g_currentGapDir = GAP_NONE;
double       g_gapPrevClose  = 0.0;  // Fechamento da vela anterior
double       g_gapOpenPrice  = 0.0;  // Abertura da vela atual (onde começou o gap)

// Máquina de estados do robô
enum EAState
  {
   STATE_WAIT_GAP = 0,   // Aguardando aparecer um gap
   STATE_WAIT_RSI = 1,   // Gap detectado, esperando confirmação pelo RSI
   STATE_IN_GRID  = 2    // Posição aberta, gerenciando grade
  };

EAState g_state = STATE_WAIT_GAP;

// Controle da grade
ENUM_ORDER_TYPE g_gridDirection   = ORDER_TYPE_BUY; // Direção da grade (BUY/SELL)
int             g_gridLevels      = 0;               // Quantidade de ordens abertas
double          g_firstEntryPrice = 0.0;             // Preço da 1ª ordem
double          g_lastEntryPrice  = 0.0;             // Preço da última ordem da grade

//==================================================================
// 3. FUNÇÕES AUXILIARES BÁSICAS
//==================================================================

// Calcula tamanho de 1 pip em preço
double PipSize()
  {
   if(_Digits == 3 || _Digits == 5)
      return(_Point * 10.0);
   return(_Point);
  }

// Limpa dados do gap atual
void ResetGap()
  {
   g_currentGapDir = GAP_NONE;
   g_gapPrevClose  = 0.0;
   g_gapOpenPrice  = 0.0;
  }

// Volta o EA para o estado inicial
void ResetEAState()
  {
   g_state           = STATE_WAIT_GAP;
   ResetGap();
   g_gridLevels      = 0;
   g_firstEntryPrice = 0.0;
   g_lastEntryPrice  = 0.0;
  }

//==================================================================
// 3.x FUNÇÕES DE INSPEÇÃO DE POSIÇÕES
//==================================================================

// Retorna true se a posição no índice idx pertence a este EA e a este símbolo
bool IsOurPositionByIndex(int idx)
  {
   if(!PositionSelectByIndex(idx))
      return(false);

   string symbol = PositionGetString(POSITION_SYMBOL);
   ulong  magic  = (ulong)PositionGetInteger(POSITION_MAGIC);

   if(symbol != _Symbol)     return(false);
   if(magic  != MagicNumber) return(false);

   return(true);
  }

// Retorna true se existe alguma posição deste EA neste símbolo
bool HasOpenPositions()
  {
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
     {
      if(IsOurPositionByIndex(i))
         return(true);
     }

   return(false);
  }

// Retorna POSITION_TYPE_BUY, POSITION_TYPE_SELL ou -1 se não tiver posição
int GetCurrentPositionType()
  {
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
     {
      if(!IsOurPositionByIndex(i))
         continue;

      ENUM_POSITION_TYPE type =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         return(POSITION_TYPE_BUY);

      if(type == POSITION_TYPE_SELL)
         return(POSITION_TYPE_SELL);
     }

   return(-1);
  }

//==================================================================
// 4. LEITURA DOS INDICADORES RSI E ATR
//==================================================================

bool GetRSI(double &rsiValue)
  {
   double buffer[1];

   if(CopyBuffer(g_handleRSI, 0, 0, 1, buffer) <= 0)
     {
      Print(__FUNCTION__, ": falha ao copiar buffer do RSI. Erro = ", GetLastError());
      return(false);
     }

   rsiValue = buffer[0];
   return(true);
  }

bool GetATR(double &atrValue)
  {
   double buffer[1];

   // ATR da barra anterior (mais estável)
   if(CopyBuffer(g_handleATR, 0, 1, 1, buffer) <= 0)
     {
      Print(__FUNCTION__, ": falha ao copiar buffer do ATR. Erro = ", GetLastError());
      return(false);
     }

   atrValue = buffer[0];
   return(true);
  }

//==================================================================
// 5. AJUSTE DE SL/TP EM UMA POSIÇÃO
//==================================================================

bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
  {
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = _Symbol;
   request.sl       = sl;
   request.tp       = tp;

   if(!OrderSend(request, result))
     {
      Print(__FUNCTION__, ": OrderSend() falhou. Erro = ", GetLastError());
      return(false);
     }

   if(result.retcode != TRADE_RETCODE_DONE)
     {
      Print(__FUNCTION__, ": retcode = ", result.retcode);
      return(false);
     }

   return(true);
  }

//==================================================================
// 6. CÁLCULO DO PREÇO MÉDIO E TAKE PROFIT DA GRADE
//==================================================================

bool UpdateGridTakeProfit(ENUM_POSITION_TYPE posType)
  {
   double totalVolume   = 0.0;
   double weightedPrice = 0.0;

   int total = PositionsTotal();

   // 1º: calcular o preço médio ponderado
   for(int i = 0; i < total; i++)
     {
      if(!IsOurPositionByIndex(i))
         continue;

      ENUM_POSITION_TYPE type =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type != posType)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double price  = PositionGetDouble(POSITION_PRICE_OPEN);

      totalVolume   += volume;
      weightedPrice += price * volume;
     }

   if(totalVolume <= 0.0)
      return(false);

   double avgPrice = weightedPrice / totalVolume;

   // 2º: definir o TP em torno do preço médio
   double tpPrice;
   if(posType == POSITION_TYPE_BUY)
      tpPrice = avgPrice + Takeprofit_Mean_Pips * g_pipSize;
   else
      tpPrice = avgPrice - Takeprofit_Mean_Pips * g_pipSize;

   // 3º: aplicar o TP em todas as posições da grade
   for(int i = 0; i < total; i++)
     {
      if(!IsOurPositionByIndex(i))
         continue;

      ENUM_POSITION_TYPE type2 =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type2 != posType)
         continue;

      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      double sl     = PositionGetDouble(POSITION_SL);

      if(!ModifyPositionSLTP(ticket, sl, tpPrice))
         Print("Falha ao ajustar TP da posição #", ticket);
     }

   return(true);
  }

//==================================================================
// 7. ABERTURA DE ORDENS DA GRADE
//==================================================================

bool OpenGridOrder(ENUM_ORDER_TYPE orderType)
  {
   double price = 0.0;

   if(orderType == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(price <= 0.0)
     {
      Print(__FUNCTION__, ": preço inválido ao abrir ordem.");
      return(false);
     }

   // Stop loss em preço
   double sl = 0.0;
   if(Stop_Loss_Pips > 0.0)
     {
      if(orderType == ORDER_TYPE_BUY)
         sl = price - Stop_Loss_Pips * g_pipSize;
      else
         sl = price + Stop_Loss_Pips * g_pipSize;
     }

   double tp = 0.0; // TP final ajustado depois via UpdateGridTakeProfit

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage_Points);

   bool ok = false;

   if(orderType == ORDER_TYPE_BUY)
      ok = trade.Buy(Lot_Size, _Symbol, price, sl, tp, "Gap+RSI Grade BUY");
   else
      ok = trade.Sell(Lot_Size, _Symbol, price, sl, tp, "Gap+RSI Grade SELL");

   if(!ok)
     {
      Print(__FUNCTION__, ": falha ao abrir ordem. RetCode = ", trade.ResultRetcode());
      return(false);
     }

   // Atualiza controle da grade
   g_gridLevels++;
   if(g_gridLevels == 1)
      g_firstEntryPrice = price;

   g_lastEntryPrice = price;
   g_gridDirection  = orderType;

   // Ajusta TP das posições dessa direção
   ENUM_POSITION_TYPE posType =
     (orderType == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);

   UpdateGridTakeProfit(posType);

   return(true);
  }

// Abre a primeira ordem da grade após confirmação pelo RSI
bool OpenFirstGridOrder(ENUM_ORDER_TYPE orderType)
  {
   if(HasOpenPositions())
     {
      Print(__FUNCTION__, ": já existe posição aberta. Não abrirá nova grade.");
      return(false);
     }

   g_gridLevels      = 0;
   g_firstEntryPrice = 0.0;
   g_lastEntryPrice  = 0.0;

   bool ok = OpenGridOrder(orderType);

   if(ok)
     {
      g_state = STATE_IN_GRID;
      ResetGap(); // Após entrar na operação, o gap já cumpriu o papel
      Print("Primeira ordem da grade aberta. Direção = ",
            (orderType == ORDER_TYPE_BUY ? "COMPRA" : "VENDA"),
            " | Preço = ", g_lastEntryPrice);
     }

   return(ok);
  }

// Abre novas ordens na grade quando o preço anda contra
bool OpenAdditionalGridOrder()
  {
   if(!HasOpenPositions())
      return(false);

   if(g_gridLevels >= Max_Grid_Levels)
      return(false);

   return(OpenGridOrder(g_gridDirection));
  }

//==================================================================
// 8. DETECÇÃO DE NOVA BARRA E GAP
//==================================================================

void DetectNewBarAndGap()
  {
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == 0)
      return;

   // Primeira chamada: só inicializa
   if(g_lastBarTime == 0)
     {
      g_lastBarTime  = currentBarTime;
      g_lastBarClose = iClose(_Symbol, PERIOD_CURRENT, 1);
      return;
     }

   // Se ainda é a mesma barra, não faz nada
   if(currentBarTime == g_lastBarTime)
      return;

   // Nova barra nasceu
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double currOpen  = iOpen(_Symbol, PERIOD_CURRENT, 0);

   g_lastBarTime  = currentBarTime;
   g_lastBarClose = prevClose;

   // Só procuramos gap se não há grade ativa
   if(g_state != STATE_WAIT_GAP || HasOpenPositions())
      return;

   double atr;
   if(!GetATR(atr))
      return;

   double gapSize = MathAbs(currOpen - prevClose);
   double minGap  = atr * Gap_Size_Multiplier;

   // Gap pequeno, ignora
   if(gapSize < minGap)
      return;

   // Gap de alta
   if(currOpen > prevClose)
     {
      g_currentGapDir = GAP_UP;
      g_gapPrevClose  = prevClose;
      g_gapOpenPrice  = currOpen;
      g_state         = STATE_WAIT_RSI;

      Print("GAP de ALTA detectado. Open=", currOpen,
            " | CloseAnterior=", prevClose,
            " | ATR=", atr,
            " | GapSize=", gapSize);
      return;
     }

   // Gap de baixa
   if(currOpen < prevClose)
     {
      g_currentGapDir = GAP_DOWN;
      g_gapPrevClose  = prevClose;
      g_gapOpenPrice  = currOpen;
      g_state         = STATE_WAIT_RSI;

      Print("GAP de BAIXA detectado. Open=", currOpen,
            " | CloseAnterior=", prevClose,
            " | ATR=", atr,
            " | GapSize=", gapSize);
      return;
     }
  }

//==================================================================
// 9. VERIFICAÇÃO SE O GAP FOI FECHADO
//==================================================================

bool IsGapClosed()
  {
   if(g_currentGapDir == GAP_NONE)
      return(false);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return(false);

   // Gap de baixa fecha quando o preço volta até o fechamento anterior
   if(g_currentGapDir == GAP_DOWN)
      return(price >= g_gapPrevClose);

   // Gap de alta fecha quando o preço cai até o fechamento anterior
   if(g_currentGapDir == GAP_UP)
      return(price <= g_gapPrevClose);

   return(false);
  }

//==================================================================
// 10. CONFIRMAÇÃO PELO RSI
//==================================================================

void HandleWaitRSI()
  {
   // Se entrou alguma posição manual / externa, o EA ajusta o estado
   if(HasOpenPositions())
     {
      g_state = STATE_IN_GRID;
      ResetGap();
      return;
     }

   // Gap foi fechado antes do RSI bater nos níveis -> cancela sinal
   if(IsGapClosed())
     {
      Print("Gap fechado antes do RSI confirmar. Resetando lógica.");
      ResetEAState();
      return;
     }

   double rsi;
   if(!GetRSI(rsi))
      return;

   // Gap de BAIXA + RSI em sobrevenda → COMPRA
   if(g_currentGapDir == GAP_DOWN && rsi <= RSI_Oversold)
     {
      Print("RSI em sobrevenda após gap de baixa. Abrindo COMPRA.");
      OpenFirstGridOrder(ORDER_TYPE_BUY);
      return;
     }

   // Gap de ALTA + RSI em sobrecompra → VENDA
   if(g_currentGapDir == GAP_UP && rsi >= RSI_Overbought)
     {
      Print("RSI em sobrecompra após gap de alta. Abrindo VENDA.");
      OpenFirstGridOrder(ORDER_TYPE_SELL);
      return;
     }
  }

//==================================================================
// 11. GERENCIAMENTO DA GRADE
//==================================================================

void HandleGrid()
  {
   // Se todas as posições foram fechadas (TP ou manual)
   if(!HasOpenPositions())
     {
      Print("Grade encerrada. Voltando ao estado inicial.");
      ResetEAState();
      return;
     }

   int posTypeInt = GetCurrentPositionType();
   if(posTypeInt != POSITION_TYPE_BUY && posTypeInt != POSITION_TYPE_SELL)
     {
      Print("Não foi possível identificar o tipo da posição. Resetando EA.");
      ResetEAState();
      return;
     }

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)posTypeInt;

   g_gridDirection = (posType == POSITION_TYPE_BUY ?
                      ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   // Atualiza TP da grade periodicamente
   UpdateGridTakeProfit(posType);

   double price;
   if(g_gridDirection == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(price <= 0.0)
      return;

   // Inicializa se por algum motivo ainda estiver zerado
   if(g_gridLevels <= 0)
     {
      g_gridLevels      = 1;
      g_firstEntryPrice = price;
      g_lastEntryPrice  = price;
     }

   bool needNewLevel = false;

   // Em compra, grade é montada para baixo (preço caindo)
   if(g_gridDirection == ORDER_TYPE_BUY)
     {
      if(price <= g_lastEntryPrice - Grid_Step_Pips * g_pipSize)
         needNewLevel = true;
     }
   else // Em venda, grade montada para cima (preço subindo)
     {
      if(price >= g_lastEntryPrice + Grid_Step_Pips * g_pipSize)
         needNewLevel = true;
     }

   if(needNewLevel && g_gridLevels < Max_Grid_Levels)
     {
      Print("Abrindo novo nível da grade: nível ",
            g_gridLevels + 1, " de ", Max_Grid_Levels);
      OpenAdditionalGridOrder();
     }
  }

//==================================================================
// 12. CICLO PADRÃO DO EA
//==================================================================

int OnInit()
  {
   g_pipSize = PipSize();

   // Cria indicadores
   g_handleRSI = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   if(g_handleRSI == INVALID_HANDLE)
     {
      Print("Erro ao criar RSI. Erro = ", GetLastError());
      return(INIT_FAILED);
     }

   g_handleATR = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(g_handleATR == INVALID_HANDLE)
     {
      Print("Erro ao criar ATR. Erro = ", GetLastError());
      return(INIT_FAILED);
     }

   ResetEAState();
   g_lastBarTime  = 0;
   g_lastBarClose = 0.0;

   Print("EA_Gap_RSI_Grade iniciado.");
   Print("Config: RSI(", RSI_Period,
         "|OB=", RSI_Overbought, "|OS=", RSI_Oversold,
         "), ATR=", ATR_Period,
         ", GapMult=", Gap_Size_Multiplier,
         ", GridStep=", Grid_Step_Pips,
         ", MaxLevels=", Max_Grid_Levels,
         ", TP_Mean=", Takeprofit_Mean_Pips, " pips.");

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_handleRSI != INVALID_HANDLE)
      IndicatorRelease(g_handleRSI);

   if(g_handleATR != INVALID_HANDLE)
      IndicatorRelease(g_handleATR);

   Print("EA_Gap_RSI_Grade finalizado. Reason=", reason);
  }

void OnTick()
  {
   // 1) Detecta nascimento de novo candle e possíveis gaps
   DetectNewBarAndGap();

   // 2) De acordo com o estado, faz uma coisa por vez
   switch(g_state)
     {
      case STATE_WAIT_GAP:
         // Só esperando um gap grande aparecer
         break;

      case STATE_WAIT_RSI:
         // Gap já visto, agora vemos se o RSI confirma
         HandleWaitRSI();
         break;

      case STATE_IN_GRID:
         // Estamos dentro da grade, ajustar níveis e TP
         HandleGrid();
         break;

      default:
         ResetEAState();
         break;
     }
  }
//+------------------------------------------------------------------+
