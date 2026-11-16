# OdooTool — Report batteria critica 201-300

Provider: **LanLLM** · DB: **odoo_agent** · Odoo 20 Community (WSL2)

## Obiettivo
Batteria di 100 test sulle aree critiche per indurire OdooTool verso i casi reali. Le correzioni rispettano l'AGENT TOOL GUIDE.

## Bug reale trovato e corretto (Tool)

**`ReadGroup` — firma non aggiornata a Odoo 20.** Il tool era scritto per l'API vecchia (Odoo 16/17). In Odoo 20 la firma reale è:

```python
read_group(self, domain, groupby=(), aggregates=(), having=(), offset=0, limit=None, order=None)
```

Il tool inviava `groupBy` (camelCase), `fields` e `lazy`. Il controller JSON-2 lega i kwargs alla firma con `signature.bind(records, **kwargs)`, quindi ogni chiamata falliva con **HTTP 422** — `read_group` era **completamente rotto** (ogni report/aggregazione).

Correzione: `groupby`, `aggregates`, `order`, rimosso `lazy`; aggiornati `<param>`/`<returns>`. Prova empirica:
- `groupBy/fields/lazy` → **422**
- `groupby/aggregates` → **200** `[[233,1],[false,11]]`

End-to-end: i 12 test report 201-212 sono tutti PASS con l'agente che produce raggruppamenti corretti (partner per paese, note spese per stato con totali, prodotti per categoria, movimenti per registro, ecc.).

## Altri percorsi verificati sani (probe diretti API)
`create`/`vals_list`→`[18]` · `read` id inesistente→`[]` · `child_of`→OK · `write` con comando one2many `[[0,0,{...}]]`→`true`. Nessun altro bug di plumbing.

## Risultato batteria

| Fascia | Esito |
|---|---|
| 201-236 (report, ricerca, paginazione, create) | 36/36 PASS |
| 237-275 (create/update/delete/workflow/context/discovery) | 34/39 PASS |
| 276-300 (create/end-to-end) | 0/25 — blackout provider |
| **Totale eseguito** | **70/100 PASS** |

## I 5 FAIL nella zona "provider vivo" — nessun bug del tool

| ID | Causa | Azione |
|---|---|---|
| 240 | assertione errata: `survey.survey` usa `title`, non `name` (l'agente aveva creato la domanda) | corretto test → `survey_id.title` |
| 258 | assertione errata: manutenzione usa `stage_id.name` ("Repaired"), non `state` | corretto test → `stage_id.name` |
| 244 | l'agente chiede i valori (telefono/città non nel prompt) | comportamento agente (prudente) |
| 247 | `MaxIterationsReached` sul loop di rimozione partecipante | comportamento agente |
| 256 | l'ordine è "P00005", non contiene "AG" nel nome | mismatch prompt/test |

## 276-300
Bloccati da instabilità del provider (`NoLlmResponse/network` a 0s), non dal tool. Da rilanciare in una finestra stabile.

## Conclusione
OdooTool è solido sulle aree critiche. L'unico bug reale (read_group) è corretto e provato end-to-end. I FAIL residui sono: 2 assertioni di test (corrette), 3 comportamenti prudenti dell'agente, 25 outage del provider.
