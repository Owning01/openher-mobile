/// Respuestas del lector: decisiones, strikes, ediciones y comentarios.
///
/// Replica la hoja **Respond** de la skill: la misma respuesta markdown que el
/// runtime JS genera (`# Re: <título>` con Decisiones, Ediciones, Struck y
/// Comentarios), para pegársela al asistente. Persiste en
/// `shared_preferences` bajo la clave del plan para que recargar no borre nada.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_model.dart';

/// Todo lo que el lector contestó en un plan.
final class PlanAnswers extends ChangeNotifier {
  PlanAnswers({required this.planKey});

  /// Clave de persistencia (título del plan).
  final String planKey;

  /// `askId` → valores elegidos (`radio`: un value; `check`: varios;
  /// `text`/`area`/`range`: el texto; `rank`: values en orden).
  final Map<String, List<String>> picked = {};

  /// Filas tachadas: `calls:<n>`.
  final Set<String> strikes = {};

  /// Ediciones de schemas/drafts: `id` → texto nuevo.
  final Map<String, String> edits = {};

  /// Comentarios: `clave` → texto (`claim:<n>`, `calls:<n>`, …).
  final Map<String, String> comments = {};

  /// Estado actual de cada máquina (por nombre).
  final Map<String, String> machineStates = {};

  /// Default de un ask (el `checked` que traía el plan).
  void applyDefaults(PlanAsk ask) {
    for (final c in ask.controls) {
      if (picked.containsKey(_key(ask.id, c))) continue;
      switch (c.kind) {
        case 'radio':
          final def = c.options.where((o) => o.checked).firstOrNull;
          picked[_key(ask.id, c)] = [if (def != null) def.value];
        case 'check':
          picked[_key(ask.id, c)] = [
            for (final o in c.options)
              if (o.checked) o.value,
          ];
        case 'text':
        case 'area':
        case 'range':
          picked[_key(ask.id, c)] = [c.value];
        case 'rank':
          picked[_key(ask.id, c)] = [for (final o in c.options) o.value];
      }
    }
  }

  static String _key(String askId, AskControl c) => '$askId:${c.name}';

  List<String> valuesOf(String askId, AskControl c) =>
      picked[_key(askId, c)] ?? const [];

  void setValues(String askId, AskControl c, List<String> values) {
    picked[_key(askId, c)] = values;
    _save();
    notifyListeners();
  }

  void toggleStrike(String key) {
    if (!strikes.remove(key)) strikes.add(key);
    _save();
    notifyListeners();
  }

  void setEdit(String id, String text) {
    edits[id] = text;
    _save();
    notifyListeners();
  }

  void setComment(String key, String text) {
    if (text.trim().isEmpty) {
      comments.remove(key);
    } else {
      comments[key] = text.trim();
    }
    _save();
    notifyListeners();
  }

  void setMachineState(String name, String state) {
    machineStates[name] = state;
    _save();
    notifyListeners();
  }

  void reset() {
    picked.clear();
    strikes.clear();
    edits.clear();
    comments.clear();
    machineStates.clear();
    _save();
    notifyListeners();
  }

  /// Decisiones sin abrir, para el botón "N por responder".
  int unanswered(List<({PlanAsk ask, String number})> asks, Set<String> seen) {
    var n = 0;
    for (final entry in asks) {
      if (!seen.contains(entry.ask.id)) n++;
    }
    return n;
  }

  /// Respuesta markdown con el formato de la skill (`# Re: <título>`).
  String buildResponse(PlanDocument plan, Set<String> seenAsks) {
    final buf = StringBuffer('# Re: ${plan.title}\n## Decisions\n');
    final asks = allAsksOf(plan);
    for (var i = 0; i < asks.length; i++) {
      final entry = asks[i];
      final pickedLabels = _pickedLabels(entry.ask);
      final kept = seenAsks.contains(entry.ask.id);
      buf.write('${i + 1}. [${entry.number}] ${entry.ask.question}\n');
      buf.write('   → **${pickedLabels.join(', ')}**');
      if (pickedLabels.length == 1) buf.write(' `${pickedLabels.single}`');
      buf.write(kept ? ' _(kept as proposed)_\n' : ' _(not opened; default kept)_\n');
    }
    if (edits.isNotEmpty) {
      buf.write('## Edits\n');
      edits.forEach((id, text) {
        buf.write('### $id\n```diff\n$text\n```\n');
      });
    }
    if (strikes.isNotEmpty) {
      buf.write('## Struck from the plan\n');
      for (final s in strikes) {
        buf.write('- **$s**\n');
      }
    }
    if (comments.isNotEmpty) {
      buf.write('## Comments\n');
      comments.forEach((key, text) {
        buf.write('- **$key**\n  > $text\n');
      });
    }
    return buf.toString();
  }

  List<String> _pickedLabels(PlanAsk ask) {
    final out = <String>[];
    for (final c in ask.controls) {
      final values = valuesOf(ask.id, c);
      if (c.kind == 'rank') {
        out.add(values.join(' > '));
      } else if (c.kind == 'text' || c.kind == 'area' || c.kind == 'range') {
        if (values.isNotEmpty && values.single.isNotEmpty) out.add(values.single);
      } else {
        for (final v in values) {
          final opt = c.options.where((o) => o.value == v).firstOrNull;
          out.add(opt == null || opt.label.isEmpty ? v : opt.label);
        }
      }
    }
    return out;
  }

  /// Todos los asks del plan con su número (`1.2`, `3.1`…).
  static List<({PlanAsk ask, String number})> allAsksOf(PlanDocument plan) {
    final out = <({PlanAsk ask, String number})>[];
    void walk(List<PlanClaim> claims, String prefix) {
      var n = 0;
      for (final claim in claims) {
        if (claim.aux.isNotEmpty) continue;
        n++;
        final number = prefix.isEmpty ? '$n' : '$prefix.$n';
        if (claim.ask != null) out.add((ask: claim.ask!, number: number));
        walk(claim.children, number);
      }
    }

    walk(plan.claims, '');
    return out;
  }

  /// `data-if="retry=no"`, `!=`, `~` (contiene) y `&&`.
  bool conditionHolds(String condition) {
    var ok = true;
    for (final part in condition.split('&&')) {
      if (!_singleHolds(part.trim())) ok = false;
    }
    return ok;
  }

  bool _singleHolds(String part) {
    if (part.contains('!=')) {
      final kv = part.split('!=');
      return _askValue(kv[0].trim()) != kv[1].trim();
    }
    if (part.contains('~')) {
      final kv = part.split('~');
      return _askValue(kv[0].trim()).contains(kv[1].trim());
    }
    if (part.contains('=')) {
      final kv = part.split('=');
      return _askValue(kv[0].trim()) == kv[1].trim();
    }
    return false;
  }

  /// Valor actual de `askId` o `askId:control`.
  String _askValue(String name) {
    if (name.contains(':')) {
      final values = picked[name];
      return values == null ? '' : values.join(',');
    }
    final matches = picked.entries.where((e) => e.key.startsWith('$name:'));
    return matches.map((e) => e.value.join(',')).join(',');
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('plan:$planKey');
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      (map['picked'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        picked[k] = [for (final x in (v as List)) x.toString()];
      });
      strikes.addAll([
        for (final x in (map['strikes'] as List? ?? [])) x.toString(),
      ]);
      (map['edits'] as Map<String, dynamic>? ?? {}).forEach(
        (k, v) => edits[k] = v.toString(),
      );
      (map['comments'] as Map<String, dynamic>? ?? {}).forEach(
        (k, v) => comments[k] = v.toString(),
      );
      (map['machines'] as Map<String, dynamic>? ?? {}).forEach(
        (k, v) => machineStates[k] = v.toString(),
      );
      notifyListeners();
    } catch (_) {
      // Sin persistencia no hay veredicto: se arranca vacío.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('plan:$planKey', jsonEncode({
        'picked': picked,
        'strikes': strikes.toList(),
        'edits': edits,
        'comments': comments,
        'machines': machineStates,
      }));
    } catch (_) {
      // Guardar es best-effort: la sesión en memoria sigue valiendo.
    }
  }
}
