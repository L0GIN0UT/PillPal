# Consent to process health data (RU region)

> **Courtesy translation** of `docs/legal/ru/consent-health-data.md`; the Russian text prevails.
> **DRAFT, not legal advice.** Kind `health_data`, version `[FILL IN]`, date `[FILL IN]`.
> Given under art. 9 and art. 10(2)(1) 152-FZ, separately from other documents, by its own tick
> **at registration**: the tick is sent with the sign-up request and recorded by the server with
> source `registration`; the e-mail address is confirmed with a mailed code afterwards. Existing
> accounts (a new text version, a restore after a deletion request) tick it in the app (source
> `in_app`). The tick is treated as consent in the form of an electronic document (art. 9(4)).
> `[FILL IN: confirm that the in-app tick equals written form — open question, see README]`

I, a PillPal user (the **subject**), freely, of my own will and in my own interest, consent to the
processing of my health data on these terms.

1. **Subject:** the account holder, identified by the account e-mail. `[FILL IN: whether name,
   address and ID document (art. 9(4)(1)) are required — the app does not collect them]`
2. **Operator:** «Пример Медтех» LLC (PLACEHOLDER), INN 0000000000, OGRN 0000000000000,
   `[FILL IN: registered address]`, privacy@example.invalid.
3. **Processors and recipients:**
   - hosting `[FILL IN: provider, Russian city]`: storage of all the data below on servers in
     Russia;
   - push delivery services Google FCM, Apple APNs and RuStore Push (VK, Russia): event metadata —
     device token, opaque profile and alert ids and the event type (e.g. that a profile has a
     missed-dose notice); never medication names, doses or intake times. `[FILL IN: FCM and APNs
     countries, art. 12 qualification]`
4. **Purposes:** storing and syncing my data between my devices; access for the relatives I allow,
   at the level I choose per medication; server-side missed-dose detection and alerts to relatives
   who turned them on, to guardians of a managed profile and to the owner of a managed profile with
   co-guardians (never to the owner of their own profile); my data export. Reminders on the device
   are local; PDF reports are made on the device.
5. **Data:** medications (name, form, strength, notes, stock, time-zone mode, privacy level,
   catalogue link, GTIN, manual composition); schedules (rule, times, doses, course dates); dose
   marks, times and notes; missed-dose records and their alert queue; sync journal; the same for
   managed profiles I keep (subject to item 9).
6. **Actions:** collection, recording, systematisation, accumulation, storage, clarification,
   retrieval, use, transfer (provision, access) to relatives I allowed at the chosen level and to
   push services as event metadata (item 3), blocking, deletion, destruction; automated processing.
7. **Term:** until the account is deleted or the consent withdrawn.
8. **Withdrawal:** in the app (Settings → Delete account) or by e-mail to privacy@example.invalid
   `[FILL IN]`. **Withdrawal means account deletion**: processing for relatives, detection and
   alerts stop at once; data is kept blocked up to 30 days only for a restore I start, then
   destroyed (art. 21(5)). After a restore the consent must be given again.
9. **Managed profiles:** entering another person's health data, I confirm I am their legal
   representative or have their consent. `[FILL IN]`
10. **Storage in Russia:** the data is stored only in databases in Russia (art. 18(5)). Medication
    names, doses and times never go to ads, analytics, logs, error reports, push messages or
    e-mails. Outside the operator's storage only relatives (item 4) and the push services (item 3,
    event metadata only) receive data.

The server records the tick with the date, time and version of this text.
