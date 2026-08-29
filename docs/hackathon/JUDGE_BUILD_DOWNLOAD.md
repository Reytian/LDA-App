# LDA Judge Build Download

The notarized macOS judge build is split into 43 transfer parts because the
bundled on-device model makes the archive larger than the upload service's
single-file limit.

1. Download all 43 files named
   `LDA-1.0-openai-build-week-c920aff.zip.part-00` through `part-42` into the
   same folder.
2. Open Terminal in that folder and run:

   ```sh
   cat LDA-1.0-openai-build-week-c920aff.zip.part-* > LDA-1.0-openai-build-week-c920aff.zip
   ```

3. Verify the reconstructed archive:

   ```sh
   shasum -a 256 LDA-1.0-openai-build-week-c920aff.zip
   ```

   Expected SHA-256:
   `7ad6a3926a32a3ffb990052ea7db6124f62c8113d113d03e877681cf1d32b0b4`

4. Unzip the archive and open `LDA.app`. The app is signed with Developer ID,
   notarized by Apple, and contains the on-device model. It needs no API key or
   network connection.

## Direct Download Links

Each part below has been shared read-only with the two official Build Week
judge accounts.

- [Part 00](https://drive.google.com/file/d/1nWD5AZCG7oX8pWFUoFk6ZQuL7Vu8R70I/view?usp=drivesdk)
- [Part 01](https://drive.google.com/file/d/1yDmIjxs9ei2Py3ns7cYW12cG3hjpJBQK/view?usp=drivesdk)
- [Part 02](https://drive.google.com/file/d/12raRa6XJ5VlGKjXUdjmN0_QjryZwbltq/view?usp=drivesdk)
- [Part 03](https://drive.google.com/file/d/1y19hxlgDZjwMa6JhZBiLp-1LrkrBoh-Q/view?usp=drivesdk)
- [Part 04](https://drive.google.com/file/d/1qvR-5hlDAxGe8z-eHKw3E5Ca5K-IxFiF/view?usp=drivesdk)
- [Part 05](https://drive.google.com/file/d/1rhOVuI-iq1ngXcRG_Jz85gIx6XqGe0Ak/view?usp=drivesdk)
- [Part 06](https://drive.google.com/file/d/1rKUaw3OGWUjT5NW45fRxnxmCIAljFP-q/view?usp=drivesdk)
- [Part 07](https://drive.google.com/file/d/1wHQRPg5vXMljB_guQ8f8ANr7VqKUZCRG/view?usp=drivesdk)
- [Part 08](https://drive.google.com/file/d/1OnwkgapYQgBU4z3416xUBROOJRsYfxox/view?usp=drivesdk)
- [Part 09](https://drive.google.com/file/d/1jaEM_Rjr_GB6iTJ74q4SBEBC9MhnJXJ-/view?usp=drivesdk)
- [Part 10](https://drive.google.com/file/d/1qGw74x-ao6FqDXfmYsvZ-v07lVbqzCS5/view?usp=drivesdk)
- [Part 11](https://drive.google.com/file/d/1WKlWhnxf5BbqzdWvRm3jz-kjZhJtXZaL/view?usp=drivesdk)
- [Part 12](https://drive.google.com/file/d/1X3GblPcMH7cr87fsRWRFkHNGnlY0zZME/view?usp=drivesdk)
- [Part 13](https://drive.google.com/file/d/1qmt012iLUSJKcLXioM50hxw16KMPvcsp/view?usp=drivesdk)
- [Part 14](https://drive.google.com/file/d/1UOTkl19Y6ekEd_YaHXiSQl7tobQsJRxe/view?usp=drivesdk)
- [Part 15](https://drive.google.com/file/d/1Qu7tlqB4wuidMUdqP_E8Vih3KAr8z6fm/view?usp=drivesdk)
- [Part 16](https://drive.google.com/file/d/1uAg_54rYNLRCCAntBOBLH9Q2vVJBvj2W/view?usp=drivesdk)
- [Part 17](https://drive.google.com/file/d/1y5_s4QPqwd8UOuaaV-bCD6m4q5hfyGjN/view?usp=drivesdk)
- [Part 18](https://drive.google.com/file/d/1tN8Na5gn8mpwTN2WqK1D7dl_QUDeNGO2/view?usp=drivesdk)
- [Part 19](https://drive.google.com/file/d/1Tat4Gj2KH6lgmQT6i_OrAfGOCYE7iQPZ/view?usp=drivesdk)
- [Part 20](https://drive.google.com/file/d/1pYD1Rp6H7wlpRwWBe95suQcmPIMSozdb/view?usp=drivesdk)
- [Part 21](https://drive.google.com/file/d/1cwKufta922YPWMFsmMTMrrgXswWJAFRn/view?usp=drivesdk)
- [Part 22](https://drive.google.com/file/d/1mkgXxvlxL0n48Q7SoMcDMemqkMVN247m/view?usp=drivesdk)
- [Part 23](https://drive.google.com/file/d/1m64s_0m3krRez8gsoNybgdF414TWoLZY/view?usp=drivesdk)
- [Part 24](https://drive.google.com/file/d/1M4A-a8nGSYzHiCNQ6AT_vPwPTO6DA3-N/view?usp=drivesdk)
- [Part 25](https://drive.google.com/file/d/1OfwoPPjYTdP7kmhhqNohAcG4LqZuzWYK/view?usp=drivesdk)
- [Part 26](https://drive.google.com/file/d/1y5C6MHfX5oVqNGvR1S5Z0t5JWievbcoo/view?usp=drivesdk)
- [Part 27](https://drive.google.com/file/d/1R9KnfPvLpoGzRs6iHtCe_h-G2c2eR9WB/view?usp=drivesdk)
- [Part 28](https://drive.google.com/file/d/1XhVhmT1_EW6Rt_jh4FkGkbr8kEXNNhkL/view?usp=drivesdk)
- [Part 29](https://drive.google.com/file/d/1XR7B0IejLs794y9HgPKVSwgPxAeNIsRK/view?usp=drivesdk)
- [Part 30](https://drive.google.com/file/d/1Ad_VHqtaioozZE9ANmeviLOFl1kYLbDh/view?usp=drivesdk)
- [Part 31](https://drive.google.com/file/d/1r4QzFaYpvkB6cEU5FlNZEnDsenPd4FcC/view?usp=drivesdk)
- [Part 32](https://drive.google.com/file/d/1m9j8Lfjd3fpic7dH86R5dfCzJKZRGVOv/view?usp=drivesdk)
- [Part 33](https://drive.google.com/file/d/1jg918rlNXMTW_cULVLosBZXzOCGwhnU9/view?usp=drivesdk)
- [Part 34](https://drive.google.com/file/d/14XUZ8l54EeqOA3plXx3iI3NW3fW8r53a/view?usp=drivesdk)
- [Part 35](https://drive.google.com/file/d/18Jh0ad0nscolCHAHbbBs0Uobe2JkM9kn/view?usp=drivesdk)
- [Part 36](https://drive.google.com/file/d/18tFl2wu1NUzVQyOfnz1I3aOunX6-ztI5/view?usp=drivesdk)
- [Part 37](https://drive.google.com/file/d/1uI4KbDEJNQcy6kWWlffXIqDU6leEGz7S/view?usp=drivesdk)
- [Part 38](https://drive.google.com/file/d/1fbMEMxoogvIjRPW76a-PHnWLKI-R7msy/view?usp=drivesdk)
- [Part 39](https://drive.google.com/file/d/1rH8ssTxpB9LPJ0oXjJ-Q_8hAo-2MM6ce/view?usp=drivesdk)
- [Part 40](https://drive.google.com/file/d/1b7uryVu_PTaOiIwuc1AVjIjpokyVT50r/view?usp=drivesdk)
- [Part 41](https://drive.google.com/file/d/1moJ32IQtehRHznUk8fZdospeKX6f3_aJ/view?usp=drivesdk)
- [Part 42](https://drive.google.com/file/d/1vPYIzcl_ryDCFKpdUSa4ygBmqm9dnYIh/view?usp=drivesdk)
