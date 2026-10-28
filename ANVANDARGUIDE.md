# Användarguide: flytta en Windows-VM från VMware till Proxmox

Guiden beskriver hur du använder migreringsskripten tillsammans med er
Veeam-återläsning. Du arbetar i Windows via VM-konsolen och använder normalt
bara tre menyval.

| Menyval | Var körs det? | Vad gör det? |
|---|---|---|
| **1) ReadinessCheck** | På original-VM:en i VMware | Kontrollerar servern och skriver rapporter. Ändrar inte inställningar. |
| **2) Prepare** | På original-VM:en i VMware | Förbereder VirtIO-lagringsdrivrutinen, sparar serverns konfiguration och stoppar/inaktiverar VMware Tools-tjänster. |
| **3) ValidatePost** | På den återställda VM:en i Proxmox | Kontrollerar att Firstboot är klart, återställer nätverksinställningar, avinstallerar kvarvarande VMware Tools och kontrollerar resultatet. |

**Mellan steg 2 och 3 gör du backup och återläsning enligt er migreringsrutin.**
Skripten utför inte själva Veeam-backupen, återläsningen eller konfigurationen
av Proxmox.

## Innan du börjar

- Ha tillgång till VM-konsolen och ett administratörskonto som fungerar även
  när Windows saknar nätverk.
- Använd hela den granskade skriptmappen (repots rot), inklusive
  `Migration.Common.ps1` och `virtio-win-guest-tools.exe`. Kopiera inte bara
  huvudskriptet.
- Kontrollera vilka Proxmox-nät, bryggor och VLAN varje nätverkskort ska anslutas till.
- Behåll original-VM:en och backupen tills flytten har verifierats.
  Originalet och den återställda kopian ska inte samtidigt vara aktiva på samma
  produktionsnät med samma IP-/MAC-adresser.
- Guidens standardflöde förbereder **VirtIO SCSI**. Använd den lagringsbuss och
  återläsningsmetod som har verifierats i er miljö.

Skripten riktar sig till Windows Server 2016, 2019, 2022 och 2025 med Windows
PowerShell 5.1. Det innebär inte att alla serverroller och versioner av
Veeam/Proxmox är färdigtestade. Prova representativa servrar innan större batcher.

## Starta menyn

Öppna **Windows PowerShell som administratör** på den VM där steget ska köras.
Gå till den lokala skriptmappen. Exempel:

```powershell
cd C:\temp\proxmox-migration
.\Migrate-VmwareToProxmox.ps1
```

Anpassa sökvägen till den plats där du har lagt filerna. Menyn visar:

```text
1) ReadinessCheck  2) Prepare  3) ValidatePost  4) Exit
```

Skriv siffran för önskat steg och tryck Enter. Menyn avslutas efter körningen;
starta huvudskriptet igen för nästa steg.

### Vanlig server eller domänkontrollant väljs automatiskt

Det tidigare valet mellan standardserver och DC har ersatts av automatisk
identifiering i Windows. En domänansluten medlemsserver räknas som `Normal`;
en domänkontrollant räknas som `DomainController`. Rollen visas vid varje körning:

```text
Phase: ReadinessCheck. Detected server type: DomainController.
```

Du använder samma menyval oavsett servertyp:

### Kontrollnivå: migreringskontroll eller fördjupad kontroll

Vid menyval **1** väljer du nivå. Enter väljer **Migreringskontroll** (`Migration`),
som fokuserar på servern som flyttas. **Fördjupad kontroll** (`Deep`) lägger till
fullständig DCDiag/DNS och fler funktionskontroller på just denna server.
Den vanliga nätverks-, Firstboot-, identitets- och lagringssäkerheten är densamma.

Nivån och före-underlaget sparas i steg 1. Steg 2 kopierar dem till
`State\MigrationAssessment` tillsammans med exporten. Om steg 1 saknas eller
underlaget är äldre än 24 timmar gör Prepare en ny lokal insamling före ändringar.
Steg 3 återanvänder nivån automatiskt. Försök inte byta nivå mellan före och efter;
kör extra djupdiagnostik separat om den behövs.

```powershell
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck -CheckLevel Migration
.\Migrate-VmwareToProxmox.ps1 -Phase ReadinessCheck -CheckLevel Deep
```

Användarspecifika tjänsteinstanser, exempelvis `CDPUserSvc_<id>` och
`WpnUserService_<id>`, ligger kvar i råunderlaget men räknas inte som saknade
servertjänster när sessionssuffixet ändras vid inloggning eller omstart.
Ny insamling sparar Windows tjänstetyp. Äldre underlag använder en begränsad lista
med kända Windows-tjänster; godtyckliga servertjänster med hexadecimala suffix
undantas inte. Detta ändrar inga tjänsters starttyp eller körläge.

Standardinsamlingen sparar lokala automatiska/centrala tjänster och, för DC,
SYSVOL/NETLOGON inklusive deras lokala katalogers tillgänglighet samt inkommande
replikeringsstatus per partner och partition. Den gör ingen domäninventering och
framtvingar ingen replikering. Avsaknad av replikeringsrader redovisas som **ej
verifierat**, inte som bevis för att domänen bara har en DC.

System- och Application-loggarna exporteras i EVTX-format för senaste 24 timmarna.
För DC exporteras också Directory Service, DFS Replication och DNS Server.
Exporten innehåller alla nivåer, så lyckad återhämtning kan granskas.
Jämförelsen sammanfattar högst 500 varnings-/felhändelser per logg; om fler finns
markeras underlaget som begränsat. Vid behov granskar driftansvarig EVTX-filerna.

Lokala insamlingsmoment har normalt 20 sekunders tidsgräns var. Native export/
repadmin begränsas till 12 sekunder. Tiden per moment skrivs i rapporten. Den
fördjupade DC-körningen har en total gräns på 300 sekunder. Timeout eller saknad
åtkomst är **ej verifierat**. En snabb process ska redovisa sin verkliga exitkod;
en saknad exitkod tolkas inte som vare sig lyckad eller misslyckad Windows-kontroll.
Insamlingsfel visar den faktiska felorsaken i rapporten och skiljs från timeout.
Inga migreringsåtgärder eller drivrutinsinstallationer
avslutas av dessa diagnostikgränser.

**Full domänkontroll är separat och valbar**, exempelvis för driftansvarig:

```powershell
.\Test-DCMigrationHealth.ps1 -Mode PreMigration
```

Det fristående kommandot ovan inventerar alla skrivbara DC:er. Använd
`-ComputerName DC05` för en enda DC. Fördjupad DC-diagnostik kräver fortfarande
ActiveDirectory-modulen; standardinsamlingen kräver den inte.

Om betrodda, nedladdade filer är blockerade kan du avblockera dem i skriptmappen:

```powershell
Unblock-File *
```

Om PowerShells körningspolicy blockerar skript kan du, om er lokala policy medger
det, tillåta körning för just det aktuella PowerShell-fönstret:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Om en central policy fortfarande blockerar körningen behöver den hanteras enligt
er vanliga rutin. Den verifierade installerarfilen i paketet kräver inga extra
flaggor för att tillåtas.

## Steg 1: kontrollera original-VM:en i VMware

Starta menyn och välj **1) ReadinessCheck**.

Kontrollen granskar bland annat nätverkskort, lagringsdrivrutiner, väntande omstart,
diskar och filsystem. Dessutom sparas lokalt driftunderlag och händelseloggar.
VSS, fullständig DCDiag och omfattande DNS-tester ingår i den fördjupade nivån.
Serverrollen identifieras automatiskt.

När readiness-kontrollen är klar visas en samlad `READINESS SUMMARY` i terminalen:
antal godkända kontroller, blockerande fel och en lista över varningar eller
kontroller som inte kunde verifieras. Alla avvikelser listas, med upp till tre
korta detaljrader per kontroll. Fullständiga detaljer finns i rapporten vars
sökväg skrivs ut direkt efter sammanfattningen.

Steg 2 avslutar även exporten med `PREPARE / STATE CAPTURE SUMMARY`, inklusive
insamlingsvarningar och sökvägar. Om förberedelsen avbryts visas `PREPARE STOPPED`.
Steg 3 visar `POST-MIGRATION SUMMARY` med blockerande fel, varningar och manuella
uppföljningar. `Migration checks` och `Operational evidence` redovisas separat:
godkända migreringskontroller innebär inte att hela serverns drift är verifierad.
Om driftunderlaget inte samlades in i körningen anges det uttryckligen.

Om lagringsdrivrutinen ännu saknas ger steg 1 en varning om att köra steg 2.
Det är normalt på en oförberedd VMware-VM och godkänner inte själva flytten.
Steg 2 måste installera och verifiera drivrutinen innan du tar migrationsbackupen.

| Resultat | Så hanterar du det |
|---|---|
| **PASS** | Kontrollen är godkänd. |
| **WARNING** | Läs förklaringen och bedöm vad som behöver åtgärdas. Varning betyder inte automatiskt att flytten ska stoppas eller godkännas. |
| **FAIL** | Utred och åtgärda felet innan du går vidare. |
| **NOT_CHECKED** | Kontrollen kunde inte utföras. Den är inte godkänd; följ upp den om funktionen behövs. |

Två eller fler nätverkskort ger en planeringsvarning. Se avsnittet om flera NIC
nedan. En varning om att NetKVM inte upptäckts bevisar inte att drivrutinspaketet
saknas, men nätverksdrivrutinen måste finnas tillgänglig vid återställningen.
Kontrollera att er verifierade återläsningsmetod hanterar detta.

## Steg 2: förbered original-VM:en i VMware

Starta menyn igen och välj **2) Prepare**.

Prepare återanvänder ett före-underlag yngre än 24 timmar från steg 1, eller
samlar in ett nytt före-underlag innan ändringarna. Vald nivå och underlaget
kopieras till exportens `State\MigrationAssessment`. Ta med hela State-mappen
i backupen. Bekräfta åtgärden när du får frågan. Prepare gör ändringar på källan:

1. Installerar det medföljande VirtIO-paketet och förbereder lagringsdrivrutinen.
   Verifieringen måste lyckas; drivrutinsfel stoppar Prepare före exporten.
2. Exporterar bland annat aktiva nätverkskort, IPv4-adresser, DNS, gateways,
   routes, tjänster, diskar och serverroller.
3. Sparar ursprungliga tjänstelägen och stoppar/inaktiverar de VMware Tools-tjänster
   som finns. Tools avinstalleras inte på original-VM:en.

**Exporten ingår redan i steg 2. Du behöver inte köra något separat exportsteg.**

BIOS-serienumret samlas in i både steg 1 och steg 2. Originalvärdet finns tydligt
i `Export-MigrationState*\State\PreMigrationState.txt` och i JSON-filens
`systemIdentity.biosSerialNumber`. Om en applikation kräver samma serienummer
efter flytten kan ni använda detta underlag när ni konfigurerar VM:en i Proxmox.
Skriptet ändrar inte serienumret automatiskt. Om värdet inte kan läsas visas en
varning. Kommandot för att kontrollera det manuellt på original-VM:en är:

```powershell
Get-CimInstance Win32_BIOS | Select-Object SerialNumber
```

Normal ordning är **1 → 2 → backup/återläsning → 3**. Du behöver inte köra
steg 1 igen efter en lyckad Prepare. Det fristående `Test-MigrationReadiness.ps1`
kräver fortfarande installerad lagringsdrivrutin som standard; menyn använder
läget `BeforePrepare` för den första kontrollen.

Vänta tills Prepare har avslutats. Gå inte vidare om fasen stoppades med ett fel.
En avbruten Prepare kan ha hunnit installera drivrutiner eller ändra inställningar;
den rullar inte automatiskt tillbaka alla tidigare åtgärder på källan.

### Spara sökvägen till exporten

Vid lyckad export skrivs en rad som börjar med `StateDirectory`. Exempel:

```text
StateDirectory: C:\Rutin_migration_2026-10-22\Export-MigrationState\State
```

Spara sökvägen i migreringsärendet. Datum och eventuella suffix varierar.
Katalogen innehåller bland annat:

- `PreMigrationState.json` – serverns sparade utgångsläge.
- `NetworkConfiguration.json` – nätverkskort och routes.
- `ipconfig-all.txt` och `route-print-4.txt` – nätverksutskrifter för felsökning.

Exporten måste finnas med i den backup som återläses. Radera eller redigera inte
JSON-filerna för att komma förbi en kontroll.

Om en planerad omstart krävs av installationen ska den hanteras före slutbackupen.
Om konfigurationen ändras efter exporten behövs en ny fångst. Behåll även den första
tjänstebaseline som togs innan Tools inaktiverades, för eventuell återgång till VMware.
Undvik att köra Prepare upprepade gånger utan anledning; det kan lämna fler
tillfälliga ROOT-hjälpenheter.

## Backup, återläsning och nätverkskort i Proxmox

Ta slutbackupen efter genomförd Prepare och följ er planerade cutover-rutin.
Återläs sedan VM:en till Proxmox med rätt lagringsbuss och rätt nätanslutningar.

### VM med ett NIC: normalt ingen manuell MAC-hantering

Du kan normalt behålla Proxmox nya MAC-adress om:

- Exporten innehåller ett aktivt källkort.
- Windows på mål-VM:en har exakt ett relevant nätverkskort.
- Målkortet identifieras som VirtIO.

Skriptet mappar då automatiskt det enda källkortet till det enda målkortet.
Loggen visar `Unique single VirtIO adapter`. IP, nätmask, DNS, gateway och
statiska IPv4-routes kan återställas även om MAC-adressen har ändrats.

Målkortet får sakna IPv4-adress före eller under återställningen, till exempel
när DHCP stängs av eller en tillfällig adress tas bort. Skriptet lägger då till
den exporterade statiska adressen. Verkliga fel vid läsning av nätverksläget
stoppar fortfarande återställningen. Samma hantering gäller vid rollback.

För en server med DHCP återställs DHCP-läget; själva adressen bestäms av
DHCP-servern. Om servern använder en reservation kopplad till den gamla
MAC-adressen behöver reservationen uppdateras eller MAC-adressen behållas.

Ytterligare relevanta adaptrar i Windows kan göra valet tvetydigt, även om du
bara har lagt till ett vanligt NIC i Proxmox. En sådan situation stoppas för granskning.

### VM med flera NIC: kopplingen måste vara entydig

Det enklaste alternativet är att behålla varje källkorts MAC-adress på motsvarande
Proxmox-kort. Adresserna finns i `NetworkConfiguration.json` och källans inventering.

1. Kontrollera vilket nät varje källkort används för.
2. På avstängd mål-VM, ange rätt MAC på rätt nätverkskort under **Hardware** i Proxmox.
3. Kontrollera brygga/VLAN för varje kort.

**Utgå inte enbart från ordningen `net0`/`net1` eller Windows-namnen.** Ett kort
utan default gateway kan ändå ha viktiga statiska routes.

Om MAC-adresserna ska ändras används i stället en mappningsfil med en post för
varje fångat källkort. Se [exemplet i README](README.md#network-restoration-and-rollback).
Starta huvudskriptet med `-AdapterMappingPath` och välj sedan samma menyval 3.

Det finns ingen hårdkodad gräns på två NIC. Routes följer sitt källkorts mappning.
Kort som är avstängda/frånkopplade på källan ingår inte i fångsten av aktiva kort;
de behöver separat planering. Sparade routes på kort utanför fångsten bevaras för
referens med varning och tilldelas inte ett annat kort automatiskt.

## Låt Firstboot bli färdigt

Starta den återställda VM:en i Proxmox. Återläsningens Guestfs/Firstboot kan installera
drivrutiner och agenter, avinstallera Tools och starta om Windows flera gånger.
Inloggningsskärmen betyder inte i sig att allt är färdigt. Antalet omstarter kan variera.

Steg 3 kontrollerar automatiskt om Firstboot är klart. Om det rapporterar `Pending`
ska det återstående arbetet få slutföras. Vid fortsatt stopp visar skriptet vilken
tjänst eller vilka filer som blockerar samt sista raden i Firstboot-loggen:

```text
C:\Program Files\Guestfs\Firstboot\log.txt
```

Den äldre Firstboot-wrappern kan stå kvar som **Running** och **Disabled** även
efter att arbetet är färdigt och loggen anger **Service uninstalled successfully**.
Steg 3 kan nu godta detta utan extra omstart om det verifierar den kända wrappern,
en tom skriptkö, en aktuell slutlogg och frånvaro av barnprocesser, relaterade
kommandon, aktiva eller ej verifierade Windows Installer-processer och aktiverade
Firstboot-jobb. Windows Installers inaktiva serviceprocess kan stå kvar efter ett
MSI-försök. Den godtas bara efter kontroll av programsökväg, serverkommando,
process-id via Windows tjänstehanterare samt att MSI-körningslåset är ledigt eller
saknas. Enbart tjänstens aktivitetsflagga räcker inte efter en misslyckad MSI-körning.
Ingen installerarprocess stoppas eller dödas.
Kontrollerna upprepas efter två sekunder och måste visa samma slutläge.
Menyn meddelar då att inget extra omstartssteg behövs för Firstboot-kontrollen.

Tjänsten stoppas eller raderas inte. Om något fortfarande arbetar, loggen är gammal
eller verifieringen inte kan utföras stoppas steg 3 med diagnostik som tidigare.
Vänta eller utred orsaken; använd inte en tom kö ensam som bevis för att allt är klart.

Du behöver inte radera `balloon.log`, ta bort tjänster eller använda någon
undantagsflagga för det vanliga Firstboot-flödet.

## Steg 3: återställ och kontrollera på Proxmox

Öppna PowerShell som administratör på den återställda VM:en, starta menyn och välj
**3) ValidatePost**. Kontrollera datornamnet i bekräftelsen innan du godkänner.

Skriptet väljer normalt den senaste exporten för samma dator. Om det inte går
att välja säkert behöver du ange den tidigare noterade sökvägen, exempelvis:

```powershell
.\Migrate-VmwareToProxmox.ps1 -StateDirectory 'C:\Rutin_migration_2026-10-22\Export-MigrationState\State'
```

Anpassa sökvägen och välj sedan **3** i menyn.

Steget verifierar Firstboot, exporten, datoridentiteten och hela NIC-mappningen.
Före första nätverksändringen sparas inställningarna för samtliga mappade målkort
i en rollback-fil. Sedan återställs IPv4/DNS/gateways/routes och kontrollerna körs.

Om VMware Tools finns kvar försöker steg 3 avinstallera paketet via MSI efter
nätverksåterställningen och före efterkontrollerna. Datornamnet måste stämma med
exporten och samtliga mappade målkort måste vara verifierade VirtIO-kort.
Firstboot kontrolleras igen före avinstallationen. Originalserverns Tools
avinstalleras inte av Prepare.

Avinstallationsloggen heter `vmware-tools-uninstall.log` i körningens loggmapp.
Skriptet kontrollerar både programregistreringen och tjänsterna VMTools,
VGAuthService, VMVss och VM3DService efteråt. Om MSI kräver omstart visas en
varning; starta om planerat och verifiera sedan med ValidateOnly. Ingen omstart
sker automatiskt. Om MSI misslyckas med kod 1603 eller 1605 finns en reservväg
för de fyra namngivna Tools-tjänsterna. Deras programsökvägar måste stämma och
alla tjänsternas registernycklar samt ursprungliga lägen säkerhetskopieras före
borttagning i `VMwareToolsServiceBackup-<id>`. Okända tjänstesökvägar eller
misslyckad backup stoppar reservvägen. Kvarvarande tjänster kan vara markerade
för borttagning tills Services-fönstret stängts eller en planerad omstart gjorts.
VMVss kan köras via Windows `dllhost.exe`. Då måste kommandoradens program-ID
stämma med COM+-katalogens VMware Snapshot Provider, tjänstenamnet VMVss och
enbart komponenten `Drivers\vss\VCBSnapshotProvider.dll` under VMware Tools
eller `VMware\Drivers\vss\VCBSnapshotProvider.dll` under Windows Common Files.
Kataloguppgifterna sparas i tjänstebackupen. COM+-registreringen och DLL-filerna
bevaras och kan behöva hanteras vid den återstående paketavinstallationen.
Reservvägen håller MSI-körningslåset exklusivt under backup och tjänstestädning
och kontrollerar att inga MSI-klienter eller Firstboot-arbeten återstår.
Ett upptaget eller ej åtkomligt lås stoppar städningen. Låset släpps även vid fel.

Reservvägen tar inte bort MSI-registreringen, filer eller drivrutiner. Den
rapporteras därför som varning med manuell uppföljning, inte som en fullständigt
lyckad paketavinstallation. Vid andra MSI-fel eller saknad programregistrering
visas vad som behöver utredas utan denna tjänstestädning.
ValidateOnly kontrollerar enbart om Tools eller tjänster finns kvar.

Om en nätverksändring misslyckas försöker skriptet återställa de berörda målkorten
till läget före försöket. Om en **senare efterkontroll** ger FAIL ligger den
framgångsrikt återställda nätverkskonfigurationen däremot kvar.

Efter kontrollerna granskas även dubbla beständiga IPv4-routes på gamla kort.
De tas bara bort om de motsvarar exporten, rätt ersättningsroute finns på
VirtIO-kortet och det gamla kortet säkert identifieras med exportens interface-GUID
och en frånvarande PnP-enhet. Om Windows rensat GUID/PnP-id från det gamla kortets
CIM-post kan kortets registerpost användas: GUID, drivrutinsbeskrivning och
anslutningsnamn måste stämma, och kortet får inte finnas i inventeringen av levande
eller dolda nätverkskort. Ett frånkopplat eller inaktiverat kort räcker inte.
Det gamla kortet får inte ha några aktiva IPv4-routes. Nätverksjämförelsen måste
vara slutförd utan fel eller ej verifierade nätverkskontroller. Ett separat fel
i exempelvis Tools-avinstallationen hindrar inte en verifierad route-städning,
men felet finns kvar i slutrapporten.

Före borttagning sparas alla planerade poster i en egen
`ObsoleteRoutesBackup-<id>.json` i efterkontrollens körningsmapp. Resultatet loggas
och kortens identitet kontrolleras igen vid borttagningen. Osäkra poster lämnas
kvar med varning för manuell granskning, exempelvis om Windows inte längre kan
visa det gamla kortets identitet. Andra routes lämnas orörda.
ValidateOnly rapporterar rester utan att ta bort dem; WhatIf ändrar ingenting.
Vid ett fel stoppas fortsatt städning. Redan borttagna poster återställs inte
automatiskt; behåll säkerhetskopian för eventuell manuell återställning.

Default-routen kan visas med ett uttryckligt metric-värde efter återställningen,
även om `route print` visade `Default` på källan. Skriptet återställer det numeriska
värde som exporterats. I testfallet är route metric 256 och kortets metric 15
både före och efter, vilket ger sammanlagd metric 271. Textskillnaden innebär
därmed inte ändrad prioritet i detta fall.

## Läs resultatet och verifiera serverns funktion

Steg 3 skriver två kompletterande resultat:

- `Reports\PostMigrationReport.html`: migreringskontroller och genomförda åtgärder,
  med separat fält `migrationChecksStatus` i JSON-rapporten.
- `Assessment\Report.html` och `AssessmentSummary.json`: driftjämförelse och
  eventloggsexporter. Baseline finns i vald exports `State\MigrationAssessment\Before`.

| Klassificering | Tolkning |
|---|---|
| Befintlig avvikelse | Fanns redan före; dokumenteras utan automatisk reparation. |
| Ny avvikelse | Tjänst/delning/replikering har försämrats och behöver bedömas. |
| Återhämtad | En tidigare observerad avvikelse har ett fungerande aktuellt resultat. |
| Ej verifierat | Underlag saknas, har timeout, är begränsat eller kan inte jämföras. |
| Ny/återkommande logghändelse | Behöver bedömas; samma ID bevisar inte samma orsak. |

Jämförelsen använder loggens identitet, record-ID, tidsstämpel, källa, ID, nivå och
meddelandetext för att skilja medföljande historik från nya/återkommande händelser.
Rensad/omskapad logg ger ej verifierat underlag. Frånvaro av ett nytt fel är inte
ensamt ett bevis för återhämtning. Replikering utan ny registrerad lyckad tid
redovisas som ej verifierad; inget synkroniseringsförsök framtvingas.

Befintliga driftavvikelser och misslyckad djupdiagnostik ger varning i arbetsflödet,
inte automatiska AD-reparationer eller stopp bara för ett gammalt DC-fel. Verkliga
migreringsfel, såsom osäker NIC-mappning eller misslyckad nätverksåterställning,
behåller sina stopp. Nya driftavvikelser kräver bedömning innan flytten godkänns.

Äldre exporter utan detta driftunderlag fungerar med nivån Migration. Rapporten
visar **ej verifierat** för före/efter; den hittar inte på ett friskt utgångsläge.
Oförenligt eller ändrat nytt underlag stoppas via datoridentitet och SHA-256-bindning
mot just den valda exporten. Manuell applikationsverifiering behövs fortfarande.

Läs slutraden **Overall result** och kontrollera särskilt:

- Att varje källkort mappas till rätt målkort och nät.
- Att IP/prefix, DNS, default gateway och nödvändiga statiska routes matchar.
- Att verkliga lagringskontrollrar, diskar, filsystem och nödvändiga tjänster fungerar.
- Att serverns applikationer, portar och beroenden faktiskt går att nå.
- Att destinationer som kräver en statisk route går att nå från rätt nät.

**En matchande route betyder att inställningen finns, inte att destinationen svarar.**
På samma sätt är en jämförelse av DNS-inställningar inte ett lyckat DNS-uppslag.

| Vanlig anmärkning | Vad betyder den? |
|---|---|
| `Capture completeness` med planeringsvarningar | Läs varningarna. Flera NIC eller saknad BitLocker-inventering innebär inte i sig en misslyckad nätverksexport. |
| `Routes on uncaptured interfaces` | En sparad route tillhör ett kort utanför fångsten. Granska den; den flyttas inte automatiskt. |
| `Preparation ROOT storage devices` | Verifierade hjälpenheter från Prepare finns kvar. De redovisas separat och tas inte bort automatiskt. Detta ersätter inte kontrollen av den verkliga lagringskontrollern. |
| `Running services` | Tjänster som körde på källan är stoppade eller saknas. Utred utifrån serverns funktion; starta inte allt blint. |
| `Listening ports` | Portlistan skiljer sig. Kontrollera särskilt de portar som applikationerna behöver. |
| `DNS connectivity: NOT_CHECKED` | Ett DNS-test saknar mål eller kunde inte utföras. För arbetsgruppsservrar används inget antaget publikt namn. Se README om `-DnsTestHost`. |

Domänkontrollanter behöver dessutom verifierad AD-replikering, DNS och övriga
kontroller enligt er rutin för domänkontrollanter. Skriptets resultat ersätter
inte serverns funktionstest eller er bedömning av när migreringen är klar.

## Kör bara kontrollerna igen

Om nätverket redan är återställt och du vill upprepa kontrollerna utan att lägga
in inställningarna igen, kör:

```powershell
.\Restore-And-TestMigrationState.ps1
```

Standardläget är **ValidateOnly**. Det läser konfigurationen och skriver nya
rapporter, men ändrar inte nätverksinställningarna.

Om det är svårt att klistra in i konsolen kan du skriva `.\Restore`, trycka
**Tab** för att komplettera filnamnet och sedan trycka Enter.

## Var finns rapporterna?

Varje körning skapar en egen katalog under `C:\Rutin_migration_ÅÅÅÅ-MM-DD`.
Sökvägarna skrivs i slutet av utskriften.

| Fil | Användning |
|---|---|
| `Reports\PostMigrationReport.html` | Läsbar efterrapport som kan öppnas i webbläsare. |
| `Reports\PostMigrationReport.txt` | Efterrapport i textformat. |
| `Reports\PostMigrationReport.json` | Strukturerat resultat för felsökning eller sammanställning. |
| `PreNetworkChangeRollback.json` | Målkortens nätverksläge före en ändring, om en ändring påbörjades. |

Spara exportens sökväg, vilken skriptversion som användes, rapporter, kvarstående anmärkningar
och funktionstestets resultat i migreringsärendet. Filerna innehåller intern
infrastrukturinformation och ska hanteras därefter.

## Vanliga stopp och nästa åtgärd

| Meddelande | Nästa åtgärd |
|---|---|
| Körning kräver administratör | Öppna Windows PowerShell som administratör och försök igen. |
| Monterad ISO/CD blockerar Prepare | Mata ut monterad media på källan och kör steget igen. |
| Installerarens hash/signatur godtas inte | Kontrollera att du använder rätt komplett skriptpaket. Tillåt inte en okänd fil genom ett generellt undantag. |
| PnPUtil 259 | Skriptet gör kompletterande kontroller. Om fasen ändå misslyckas, följ det faktiska felmeddelandet; koden ensam bevisar inte felaktig drivrutin. |
| Exporten saknas eller är ofullständig | Använd rätt StateDirectory. En misslyckad fångst måste ersättas av en fullständig fångst från källan. |
| Datornamnet matchar inte | Kontrollera VM och fångst. Använd inte Force som normal genväg. |
| `Cannot uniquely map source` | Kontrollera ett-NIC-villkoren eller rätt MAC/mappningsfil för alla kort. |
| `MIG-NET-001` | NIC-mappningen misslyckades; nätverksåterställningen har inte påbörjats. Utskriften visar källans och målets kort/MAC. Om källans MAC saknas kan den ha glömts i Proxmox; kontrollera även antal kort och drivrutiner. Stäng av mål-VM:en, sätt rätt MAC på motsvarande kort, kontrollera brygga/VLAN och kör steg 3 igen. Alternativt används en komplett mappningsfil. |
| `MIG-FIRSTBOOT-001` | Firstboot är inte verifierat klart. Läs blockerande tjänster, återstående skript och sista loggraden. Vänta eller utred loggen. |
| `MIG-FIRSTBOOT-002` | Inga skript återstår och loggen anger lyckad avinstallation, men Firstboot-tjänsten är fortfarande Running och Disabled. Starta om Windows en gång via Startmenyn i Proxmox-konsolen och kör steg 3 igen. Om stoppet kvarstår, utred loggen. |
| Verklig lagringskontroller ger FAIL | Granska enhets-ID, problemkod, drivrutin och vald lagringsbuss. Radera inte en verklig kontroller för att få grön rapport. |
| Nätverksåterställning/rollback misslyckas | Använd konsolen och granska rapport samt rollback-fil innan nästa ändringsförsök. |

### Om mål-VM:en saknar nätverk

Koderna ovan identifierar meddelandet och är inte nya numeriska returkoder.
NIC-mappningsfel i steg 3 har fortfarande returkod 20. Skriptet startar inte om
Windows eller tar bort Firstboot-tjänsten automatiskt.

För över en komplett skriptmapp via en ISO ansluten som CD/DVD i Proxmox.
Kopiera mappen från skivan till lokal disk i Windows och kör därifrån. På en
redan återställd VM ska du köra steg 3 eller ValidateOnly, inte Prepare.
Ett uppdaterat skriptpaket ska inte ersätta den sparade state-katalogen på C:.

## Återgång till VMware

En automatisk nätverksrollback på Proxmox är inte samma sak som att gå tillbaka
till original-VM:en i VMware.

Vid återgång till VMware följer du cutover-rutinen så att rätt VM är aktiv på nätet.
Återställ originalets VMware Tools-tjänster till deras sparade start-/körlägen i
`PreMigrationState.json`, under `services.all`. Att bara starta `VMTools` återställer
inte övriga tjänster som Prepare kan ha inaktiverat. Firstboot kan redan ha
avinstallerat Tools på Proxmox-kopian; den ska inte förväxlas med originalet.

## Omfattning och vidare läsning

Automatisk nätverksåterställning gäller fångade aktiva kort och IPv4. IPv6,
teaming, VLAN-inställningar, nätverksprofiler, brandväggspolicy och konfiguration
av dynamisk routing behöver separat hantering.

Se [README.md](README.md) för parametrar, mappningsfil, alternativa
återläsningsmetoder, reparationslägen och returkoder. Den svenska
[granskningen](GRANSKNING.md) beskriver ändringar, tester och kvarvarande
verifiering.
