using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    internal class JSONAccount
    {
        public string Voornaam { get; set; }
        public string Naam { get; set; }
        public string Gebruikersnaam { get; set; }
        public string Internnummer { get; set; }
        public string Status { get; set; }
        public string Extravoornamen { get; set; }
        public string Initialen { get; set; }
        public string Roepnaam { get; set; }
        public string Geslacht { get; set; }
        public string Geboortedatum { get; set; }
        public string Geboorteplaats { get; set; }
        public string Geboorteland { get; set; }
        public string Rijksregisternummer { get; set; }
        public string Straat { get; set; }
        public string Huisnummer { get; set; }
        public string Busnummer { get; set; }
        public string Postcode { get; set; }
        public string Woonplaats { get; set; }
        public string Land { get; set; }
        public string Emailadres { get; set; }
        public string Website { get; set; }
        public string Mobielnummer { get; set; }
        public string Telefoonnummer { get; set; }
        public string Fax { get; set; }
        public string Instantmessenger { get; set; }
        public string Sorteerveld { get; set; }
        public string Stamboeknummer { get; set; }
        public string Koppelingsveldschoolagenda { get; set; }
        public string Basisrol { get; set; }
        public string Klasnummer { get; set; }
        public bool IsEmailVerified { get; set; }
        public bool IsAuthenticatorAppEnabled { get; set; }
        public bool IsYubikeyEnabled { get; set; }

        [JsonProperty(PropertyName = "Naam verantwoordelijke leerlingbegeleiding")]
        public string NaamVerantwoordelijkeLeerlingbegeleiding { get; set; }
        [JsonProperty(PropertyName = "Telefoonnummer verantwoordelijke leerlingbegeleiding")]
        public string TelefoonnummerVerantwoordelijkeLeerlingbegeleiding { get; set; }
        [JsonProperty(PropertyName = "Naam verantwoordelijke CLB")]
        public string NaamVerantwoordelijkeCLB { get; set; }
        [JsonProperty(PropertyName = "Telefoonnummer verantwoordelijke CLB")]
        public string TelefoonnummerVerantwoordelijkeCLB { get; set; }
        [JsonProperty(PropertyName = "Naam ouder/voogd")]
        public string NaamOuderVoogd { get; set; }
        [JsonProperty(PropertyName = "Voornaam ouder/voogd")]
        public string VoornaamOuderVoogd { get; set; }
        [JsonProperty(PropertyName = "Geslacht ouder/voogd")]
        public string GeslachtOuderVoogd { get; set; }
        [JsonProperty(PropertyName = "Adres ouder/voogd")]
        public string AdresOuderVoogd { get; set; }
        [JsonProperty(PropertyName = "Huisnummer ouder/voogd")]
        public string HuisnummerOuderVoogd { get; set; }
        [JsonProperty(PropertyName = "Postcode ouder/voogd")]
        public string PostcodeOuderVoogd { get; set; }
        public string Optie { get; set; }
        public string Godsdienstkeuze { get; set; }
        public string Nationaliteitscode { get; set; }
        public string Nationaliteit { get; set; }
        public string Soortleerling { get; set; }
        public string Function { get; set; }
        public string Teachercardnumber { get; set; }
        public string Voornaam_coaccount1 { get; set; }
        public string Naam_coaccount1 { get; set; }
        public string Email_coaccount1 { get; set; }
        public string Telefoonnummer_coaccount1 { get; set; }
        public string Mobielnummer_coaccount1 { get; set; }
        public string Type_coaccount1 { get; set; }
        public string Voornaam_coaccount2 { get; set; }
        public string Naam_coaccount2 { get; set; }
        public string Email_coaccount2 { get; set; }
        public string Telefoonnummer_coaccount2 { get; set; }
        public string Mobielnummer_coaccount2 { get; set; }
        public string Type_coaccount2 { get; set; }
        public string Voornaam_coaccount3 { get; set; }
        public string Naam_coaccount3 { get; set; }
        public string Email_coaccount3 { get; set; }
        public string Telefoonnummer_coaccount3 { get; set; }
        public string Mobielnummer_coaccount3 { get; set; }
        public string Type_coaccount3 { get; set; }
        public string Voornaam_coaccount4 { get; set; }
        public string Naam_coaccount4 { get; set; }
        public string Email_coaccount4 { get; set; }
        public string Telefoonnummer_coaccount4 { get; set; }
        public string Mobielnummer_coaccount4 { get; set; }
        public string Type_coaccount4 { get; set; }
        public string Voornaam_coaccount5 { get; set; }
        public string Naam_coaccount5 { get; set; }
        public string Email_coaccount5 { get; set; }
        public string Telefoonnummer_coaccount5 { get; set; }
        public string Mobielnummer_coaccount5 { get; set; }
        public string Type_coaccount5 { get; set; }
        public string Voornaam_coaccount6 { get; set; }
        public string Naam_coaccount6 { get; set; }
        public string Email_coaccount6 { get; set; }
        public string Telefoonnummer_coaccount6 { get; set; }
        public string Mobielnummer_coaccount6 { get; set; }
        public string Type_coaccount6 { get; set; }
        public string Last_successful_login { get; set; }
        public string Last_successful_login_coaccount1 { get; set; }
        public string Last_successful_login_coaccount2 { get; set; }

        public List<JSONGroup> Groups { get; set; }
    }
}
