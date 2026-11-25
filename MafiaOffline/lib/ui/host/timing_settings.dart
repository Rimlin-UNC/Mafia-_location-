import 'package:flutter/material.dart';
import '../../models/phase_timings.dart';

class TimingSettings extends StatelessWidget {
  final PhaseTimings value;
  final ValueChanged<PhaseTimings> onChanged;
  const TimingSettings({super.key, required this.value, required this.onChanged});

  static const labels = {'night': 'Ночь', 'day': 'День',
    'voting': 'Голосование', 'runoff': 'Переголосование', 'lastWord': 'Последнее слово'};

  Future<void> _edit(BuildContext context, String key) async {
    final form = GlobalKey<FormState>();
    final current = value.toJson()[key]!;
    var input = current == 0 ? '' : '$current';
    final seconds = await showDialog<int>(context: context, builder: (context) => AlertDialog(
      title: Text(labels[key]!),
      content: Form(key: form, child: TextFormField(
        initialValue: input,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: 'Секунды',
          helperText: 'От 10 до ${PhaseTimings.maxFor(key)} секунд'),
        onChanged: (v) => input = v,
        validator: (v) {
          final n = int.tryParse(v?.trim() ?? '');
          return n == null || n < 10 || n > PhaseTimings.maxFor(key)
            ? 'Введите целое число от 10 до ${PhaseTimings.maxFor(key)}' : null;
        },
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(context, key == 'lastWord' ? 30 : 0),
          child: Text(key == 'lastWord' ? '30 секунд' : 'Авто')),
        TextButton(onPressed: () {
          if (form.currentState!.validate()) Navigator.pop(context, int.parse(input.trim()));
        }, child: const Text('Сохранить')),
      ],
    ));
    if (seconds != null) onChanged(value.withSeconds(key, seconds));
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Тайминги фаз'),
    subtitle: const Text('Авто или фиксированное время в секундах'),
    children: [
      const Padding(padding: EdgeInsets.all(12), child: Text(
        'Авто учитывает состав и число живых. Фиксированное время '
        'действует и в первую ночь, и в соло-партии. '
        'Если все сходили, ночь и голосование могут закончиться раньше. '
        'Ведущий может поставить паузу, продлить или завершить фазу.')),
      for (final key in PhaseTimings.keys)
        ListTile(title: Text(labels[key]!),
          trailing: Text(value.toJson()[key] == 0 ? 'Авто' : '${value.toJson()[key]} с'),
          onTap: () => _edit(context, key)),
      TextButton(onPressed: () => onChanged(const PhaseTimings()),
        child: const Text('Сбросить все тайминги')),
    ],
  );
}
