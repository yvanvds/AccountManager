using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi
{
    public interface IAccount
    {
        string UID { get; set; } // gebruikersnaam
        string AccountID { set; get; } // intern nummber
        string RegisterID { set; get; } // rijksregisternummer
        string UntisID { set; get; } // 
        int StemID { set; get; } // stamboeknummer
        AccountRole Role { set; get; }

        string GivenName { set; get; } // voornaam
        string SurName { set; get; } // naam
        string ExtraNames { set; get; } // extra voornamen
        string Initials { set; get; } // initialen
        GenderType Gender { set; get; } // geslacht

        DateTime Birthday { set; get; }
        string BirthPlace { set; get; }
        string BirthCountry { set; get; }

        string Street { set; get; }
        string HouseNumber { set; get; }
        string HouseNumberAdd { set; get; }
        string PostalCode { set; get; }
        string City { set; get; }
        string Country { set; get; }
        string MobilePhone { set; get; }
        string HomePhone { set; get; }
        string Fax { set; get; }
        string Mail { set; get; }
        string MailAlias { set; get; }

        string Group { get; set; }

        JObject ToJson();
        bool Equals(IAccount other);
    }
}
