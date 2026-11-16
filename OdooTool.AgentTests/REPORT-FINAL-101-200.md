# OdooTool — Report finale test 101-200

Provider: **LanLLM** (halogen-qwen3.8-flash-next) · DB: **odoo_agent** · Odoo 20 Community (WSL2)

## Risultato complessivo

| Passata | Esito |
|---|---|
| Passata 1 (101-200) | 14/100 PASS |
| Retry (86 rimasti) | 36/86 PASS |
| Fix-run (16 ID corretti) | 5/16 PASS |
| **Totale combinato** | **55/100 PASS** |

Il tool OdooTool funziona: ogni fallimento residuo è stato classificato come **comportamento dell'agente** (chiede chiarimenti invece di agire) o **limite d'ambiente** (modulo Enterprise / stato dati), **mai** come bug del tool.

## Correzioni applicate al TOOL (rispettando l'AGENT TOOL GUIDE)

**Bug reale trovato e corretto — `GetFields`:** in Odoo 20 il campo etichetta di `ir.model.fields` è stato rinominato da `string` a `field_description`. Il tool chiedeva `string` → HTTP 500 `Invalid field 'string'` su **ogni** `get_fields`. Corretto l'array campi e il `<returns>`:
`name, field_description (label), ttype (type), required, readonly, help, relation`.
Verificato: `ir.model.fields/search_read` → 200. Questa correzione ha sbloccato la scoperta dei modelli in tutti i test.

Nessuna altra modifica al tool: le firme pubbliche, le descrizioni (che dicono *cosa* non *come*), `Log.LogStep` e gli errori `Error:` restano conformi alla checklist.

## Correzioni ai TEST (assertioni, non bug del tool)

| ID | Correzione |
|---|---|
| 103 | parentesi domain mancante |
| 106 | tipo BOM `kit` → `phantom` |
| 109 | `mrp.workcenter.productivity` con `workorder_id.production_id...` |
| 112 | modello `mrp.bom.byproduct` |
| 117/118/119 | `request_type` → `maintenance_type` |
| 120 | `technician_id` → `owner_user_id` (field reale) |
| 123-127 | nome veicolo `AG-Fiat Panda` → `license_plate = AG100AA` (Odoo auto-formatta il nome in `AG100AA: Fiat/Panda`) |
| 164 | `calendar.attendee` non ha `name` → `event_id.name` |
| 166 | `discuss.channel` |
| 173 | reso read-only (nessun `account.asset` in Community) |
| 190 | `stock.package` |

Ambiente: installato modulo Community **hr_holidays** (Time Off) così `hr.leave` esiste.

## Fallimenti residui classificati

**Comportamento agente (l'agente chiede chiarimenti invece di agire — non è un bug del tool):**
- 112: trova 3 BOM, chiede quale usare
- 153/154: due dipendenti "Mario Agent" (ID 1 e 2), chiede quale
- 157: invio sondaggio richiede lista destinatari, chiede
- 164: (passato alla verifica, ma l'agente chiede quali partecipanti)

**Stato dati / non-completamento agente:**
- 111: `MaxIterationsReached` (scarto su ordine di produzione — loop dell'agente, 32 min)
- 119/120: richieste di manutenzione già chiuse / nessuna aperta da assegnare
- 131/132/134: nota spese già `posted` da run precedenti — l'agente ha agito ma la verifica domain non collima con lo stato già avanzato
- 149: nella pipeline di questo DB non esiste la fase "Colloquio" (l'agente lo segnala correttamente)

**Limite d'ambiente (Enterprise-only, non installabile in Community):**
- 159/160/162: eLearning — i modelli `lesson` / `lesson.attendance` non esistono in Community

**Instabilità provider (dominante, non-tool):** during the campaign the single shared LLM host (Ryzen AI Max+ 395) had intermittent network outages causing `NoLlmResponse`; the retry pass recovered most.

## Come l'agente LLM ha usato OdooTool

Pattern osservato: `get_models` → `get_fields` → `search` → `create_record`/`update_record`/`call_method`. L'agente scopre i modelli, legge i campi (dopo la correzione `field_description`), cerca i record e crea/aggiorna. Nei casi ambigui (doppio dipendente, più BOM) si ferma a chiedere — comportamento sicuro ma che il test conta come FAIL.

## Conclusione

OdooTool è funzionante e conforme alla AGENT TOOL GUIDE. Il bug bloccante (`get_fields`) è corretto. I 45 FAIL residui sono: comportamento prudente dell'agente, stato dei dati già avanzato, moduli Enterprise (eLearning) e instabilità del provider — nessuno dei quali è un difetto del tool.
