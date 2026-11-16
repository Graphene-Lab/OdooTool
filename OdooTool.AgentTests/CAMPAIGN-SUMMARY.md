# OdooTool — Campagna agentica: risultati e miglioramenti

Data: 2026-10-17 · Odoo 20 Community (WSL Ubuntu) · DB `odoo_agent` · Provider LLM: LanLLM
Report per-test: `bin/Debug/net10.0/agent-report.md`

## 1. Miglioramento applicato a OdooTool (trovato dai test)

**Contratto JSON-2 errato su create/write.**

Il tool inviava `{"values": {...}}`; l'API JSON-2 di Odoo 20 richiede:
- `create` → `{"vals_list": [ {...} ]}`
- `write` → `{"ids": [...], "vals": {...}}`

Senza il fix ogni scrittura tornava **HTTP 422** (`missing a required argument: 'vals_list'` /
`'vals'`); l'agente riprovava con nomi alternativi (`vals`, `call_method create/write`),
consumando 4-6 iterazioni e in 2 casi raggiungendo `MaxIterationsReached`.

Effetto misurato dopo il fix: test 1 da **137s → 61s**, test 3 da **149s → 59s**, scritture
riuscite al primo tentativo. Verifica diretta: `create` → `[8]`, `write` → `true`.

## 2. Come l'agente LLM ha usato OdooTool

Dai log `Log.LogStep` (`logs/<pid>.txt`):

- **Esplorazione corretta**: `get_models` → `get_fields` → `search` → operazione.
- **Recupero dagli errori**: dopo un 422 riprova con parametri alternativi; con il contratto
  corretto il primo tentativo basta.
- **Auto-verifica**: dopo la scrittura rilegge il record (`read`) e riporta i valori.
- **Ambiguità**: con più record corrispondenti (2 ordini, 2 dipendenti "Mario Agent") **chiede**
  invece di scegliere: comportamento corretto in produzione, fallimento nei test automatici.
- **Scenari contabili multi-step**: raggiungono `MaxIterations` (20) — serve un limite più alto
  o un helper dedicato (es. pagamento fattura).

## 3. Esiti

### Prima esecuzione completa (100 test)

**39 PASS / 61 FAIL**
- 43 fallimenti `NoLlmResponse/network`: provider LanLLM caduto al test 50 (non imputabili al tool).
- Fallimenti reali: 9 (verifica su record archiviato), 14 (prompt ambiguo), 17 (due ordini →
  richiesta di chiarimento), 19 (cascata), 22/25 (prodotto non stoccabile), 26 (modello errato
  nella verifica), 33 (`MaxIterations`), 35/36 (nessun dipendente nel DB).

### Rilancio dei 62 test falliti (dopo il fix e le correzioni)

**47 PASS / 15 FAIL**

PASS: 9, 17, 19, 21, 22, 25, 26, 35, 36, 50-61, 65, 68-72, 73, 75, 77-80, 85-96, 98-100.

FAIL residui e causa:
- **14** — nome listino: corretto nel sorgente dopo il run ("Listino Rossi").
- **33** — `MaxIterations` sul pagamento fornitore (scenario multi-step).
- **62, 63, 64, 66, 67** — due dipendenti "Mario Agent" (creati dal run precedente): l'agente
  chiede quale usare.
- **73, 74, 76** — dettagli modello/dati (coupon `loyalty.card`, blog non installato, nome
  prodotto cambiato).
- **81, 82, 83, 84** — nessuna configurazione POS nel DB demo: l'agente riporta correttamente
  l'assenza di `pos.config`/sessioni.
- **97** — l'agente aggiorna `standard_price` invece di creare un `product.supplierinfo`.

## 4. Conclusione

OdooTool è funzionante e usabile dall'agente: dopo il fix del contratto JSON-2 tutte le
operazioni CRUD di base (create/update/search/read/call_method/read_group) riescono al primo
colpo. I fallimenti residui sono di natura diversa: ambiguità dei prompt/test, dati demo
mancanti (POS, dipendenti), o scelte di modello dell'agente — non difetti del tool.

Raccomandazioni:
1. Mantenere il fix `vals_list`/`vals`.
2. Nei test usare nomi univoci per run o azzerare il DB.
3. Alzare `maxIterations` a 30 per gli scenari contabili.
4. Aggiungere un helper `pay_invoice` che incapsula `account.move.action_create_payments`.
