# FS22_WheelFFB

[English](README.md)

Linux'ta Farming Simulator 22 için FFB. FS22'nin kendi FFB'si Proton altında çalışmıyor, Windows'ta
da merkezleyen bir yaydan ibaret. Bu mod traktörün ne yaptığını bir FFB sunucusuna gönderir, siz de
direksiyonda hissedersiniz:

| Hissettiğiniz | Nereden geliyor |
|---|---|
| hızla artan merkezleme | aracın hızı; lastiğin daha az tuttuğu tarlada ve karda zayıflar |
| direksiyon ağırlığı | motor kapalıyken hidrolik destek olmadığı için ağırlaşır |
| tümsekler | sol ve sağ ön tekerin izlerde ve bordürlerde farklı hareket etmesi |
| darbeler | ani duruşlar ve sert inişler |
| zemin dokusu | yol, çakıl, yumuşak toprak, tarla ve kar farklı hissettirir, hızlandıkça sıklaşır |
| motor titreşimi | devri takip eder, yavaşken en güçlüdür |

```
FS22_WheelFFB (Lua modu) ──named pipe──► wheelffb-relay.exe ──WebSocket──► FFB sunucusu ──► direksiyon
     oyunun içinde          \\.\pipe\WheelFFB      oyunun yanında        ws://127.0.0.1:47820
```

FS22'nin Lua ortamında `require`, `package` ve soketler kaldırılmış; oyunda bir test moduyla
doğrulandı. Dışarıya tek yol `io`, o da Windows named pipe açabiliyor. Küçük bir aracı program
(relay) bu pipe'ı WebSocket'e çevirir. FFB sunucusu [ffb-server](https://github.com/egeSlop/ffb-server):
ister [V987 Wheel Studio](https://github.com/egeSlop/v987-wheel-studio) içinde, ister tek başına.

## Kurulum (Linux, Steam + Proton)

1. Bir FFB sunucusu kurun. [V987 Wheel Studio](https://github.com/egeSlop/v987-wheel-studio)'nun
   içinde bir tane var ve sürerken oyunu canlı gösteriyor. Penceresiz bir sunucu için
   `cargo install --git https://github.com/egeSlop/ffb-server` çalıştırın.
2. `./install.sh` çalıştırın. Relay'i derler (`x86_64-pc-windows-gnu` hedefi olan Rust ve
   `mingw64-gcc` gerekir), modu FS22'nin mod klasörüne kopyalar ve başlatma betiğini
   `~/.local/share/fs22-ffb/` içine koyar.
3. Steam'de FS22'nin başlatma seçeneklerine şunu yazın:

   ```
   PROTON_ENABLE_HIDRAW=0x11FF/0x2370 ~/.local/share/fs22-ffb/fs22-ffb-launch.sh %command%
   ```

   `PROTON_ENABLE_HIDRAW` kısmı sadece LiteStar / Rampage Pace V987 için. Başka direksiyonlarda
   silin.
4. Kayıt dosyanızın mod listesinde **Direksiyon FFB** modunu işaretleyin ve FS22'nin kendi FFB
   ayarını kapatın.

Oyunu açtığınızda başlatma betiği, Wheel Studio açıksa onun sunucusunu kullanır. Açık değilse arka
planda bir sunucu başlatır ve oyun kapanınca onu da kapatır.

## Windows (denenmedi)

Relay zaten bir Windows programı, yani aynı parçalar Windows'ta da çalışmalı ama henüz kimse
denemedi. Mod zip'ini mod klasörünüze kopyalayın, Wheel Studio'yu açın (ya da `ffb-server.exe`
çalıştırın), `start-relay-windows.bat` dosyasını çalıştırın, sonra FS22'yi açın. Sonucu
bildirirseniz seviniriz.

## Ayar yapmak

Wheel Studio'daki FFB sunucusu sayfasını kullanın. Her kaydırıcı sürerken anında uygulanır.
Uygulama olmadan `~/.config/v987-wheel-studio/ffb-server.toml` dosyasını düzenleyin, sunucu dosyayı
kendisi yeniden okur.

## Klasörler

| Yol | |
|---|---|
| `mod/FS22_WheelFFB/` | mod: araç verilerini okuyup pipe'a JSON satırları yazar |
| `relay/` | `wheelffb-relay.exe` (Rust): pipe'tan WebSocket'e aktarır, oyunu da başlatabilir |
| `launch/` | Steam başlatma betiği (Linux) ve Windows için başlatıcı |

Mod sadece FS22'nin kendi betiklerinin kullandığı değerleri okur. Her biri GIANTS SDK'daki
(`sdk/debugger/gameSource.zip`) oyun Lua kaynağıyla karşılaştırıldı; o kaynak bu depoda yok.

## Başka bir oyun için mod yazmak

FFB sunucusu FS22'ye bağlı değil. Protokol ve örnekler
[ffb-server/docs/FFB-SERVER.md](https://github.com/egeSlop/ffb-server/blob/main/docs/FFB-SERVER.md)
dosyasında. Oyununuz da soket açamıyorsa bu relay onun için de çalışır: `\\.\pipe\WheelFFB`'ye JSON
satırları yazın.

## Lisans

MIT. Kod Claude (Anthropic) ile vibecode'landı; tek bir direksiyon ve tek bir bilgisayarda denendi.
