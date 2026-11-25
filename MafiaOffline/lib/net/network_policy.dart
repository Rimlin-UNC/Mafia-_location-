/// Проверки не доверяют идентификатору внутри пользовательского сообщения.
class NetworkPolicy {
  static bool ownsCommand(String? boundId, Object? claimedId) =>
      boundId != null && claimedId is String && boundId == claimedId;

  /// Старые слоты без доказательства владения восстанавливает ведущий,
  /// а не любой участник, угадавший имя. Это не шифрование транспорта.
  static bool ownsSlot(String? storedDevice, String? suppliedDevice) =>
      storedDevice != null && storedDevice.length >= 8 &&
      suppliedDevice == storedDevice;

  static bool currentTurn(Object? supplied, int expected) =>
      supplied is int && supplied == expected;
}
