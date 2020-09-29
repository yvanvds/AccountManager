using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    public class Account : AccountApi.IAccount
    {
        /// <summary>
        /// The User ID, this is smartschool's username or login
        /// </summary>
        public string UID { get; set; } = String.Empty;

        /// <summary>
        /// This is used as smartschool's internal number
        /// </summary>
        public string AccountID { get; set; } = String.Empty;

        /// <summary>
        /// The state registry number
        /// </summary>
        public string RegisterID { get; set; } = String.Empty;

        /// <summary>
        /// Smartschool field for a Untis ID. Smartschool does not support saving this right now.
        /// </summary>
        public string UntisID { get; set; } = String.Empty;

        /// <summary>
        /// Stamboeknummer...
        /// </summary>
        public int StemID { get; set; } = 0;

        /// <summary>
        /// The account role can be student, teacher or director. IT or Support are supported internally,
        /// but will be converted to teacher when saved to smartschool.
        /// </summary>
        public AccountRole Role { get; set; } = AccountRole.Other;

        /// <summary>
        /// The given/first name of the account holder
        /// </summary>
        public string GivenName { get; set; } = String.Empty;

        /// <summary>
        /// The last name of the account holder
        /// </summary>
        public string SurName { get; set; } = String.Empty;

        /// <summary>
        /// Middle names of the account holder (optional)
        /// </summary>
        public string ExtraNames { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's initials (optional)
        /// </summary>
        public string Initials { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's gender. (Smartschool only supports male/female. Other options will be converted
        /// to female.)
        /// </summary>
        public GenderType Gender { get; set; } = GenderType.Transgender;

        /// <summary>
        /// The account holder's date of birth
        /// </summary>
        public DateTime Birthday { get; set; }

        /// <summary>
        /// The account holder's place of birth
        /// </summary>
        public string BirthPlace { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's country of birth
        /// </summary>
        public string BirthCountry { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's street address. In smartschool, this will be merged with house number and bus number
        /// </summary>
        public string Street { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's street address number. In smartschool, this will be merged with street and bus number.
        /// </summary>
        public string HouseNumber { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's street address bus number.
        /// </summary>
        public string HouseNumberAdd { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's current address postal code.
        /// </summary>
        public string PostalCode { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's current city
        /// </summary>
        public string City { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's current country
        /// </summary>
        public string Country { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's mobile phone number
        /// </summary>
        public string MobilePhone { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's home phone number
        /// </summary>
        public string HomePhone { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's fax number
        /// </summary>
        public string Fax { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's email adress
        /// </summary>
        public string Mail { get; set; } = String.Empty;

        /// <summary>
        /// The account holder's email alias (not currently used by smartschool)
        /// </summary>
        public string MailAlias { get; set; } = String.Empty;

        /// <summary>
        /// Primary group for this account holder. (Not used by smartschool)
        /// </summary>
        public string Group { get; set; } = String.Empty;

        public string Status { get; set; } = string.Empty;

        /// <summary>
        /// Create a JSON JObject containing the data in this account.
        /// </summary>
        /// <returns></returns>
        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["AccountID"] = AccountID,
                ["BirthCountry"] = BirthCountry,
                ["Birthday"] = Utils.DateToString(Birthday),
                ["BirthPlace"] = BirthPlace,
                ["City"] = City,
                ["Country"] = Country,
                ["ExtraNames"] = ExtraNames,
                ["Fax"] = Fax,
                ["Gender"] = Gender.ToString(),
                ["GivenName"] = GivenName,
                ["Group"] = Group,
                ["HomePhone"] = HomePhone,
                ["HouseNumber"] = HouseNumber,
                ["HouseNumberAdd"] = HouseNumberAdd,
                ["Initials"] = Initials,
                ["Mail"] = Mail,
                ["MailAlias"] = MailAlias,
                ["MobilePhone"] = MobilePhone,
                ["PostalCode"] = PostalCode,
                ["RegisterID"] = RegisterID,
                ["Role"] = Role.ToString(),
                ["StemID"] = StemID,
                ["Street"] = Street,
                ["SurName"] = SurName,
                ["UID"] = UID,
                ["UntisID"] = UntisID,
                ["Status"] = Status,
            };
            return result;
        }

        public Account() { }

        public Account(JObject obj)
        {
            AccountID = obj["AccountID"].ToString();
            BirthCountry = obj["BirthCountry"].ToString();
            Birthday = Utils.StringToDate(obj["Birthday"].ToString());
            BirthPlace = obj["BirthPlace"].ToString();
            City = obj["City"].ToString();
            Country = obj["Country"].ToString();
            ExtraNames = obj["ExtraNames"].ToString();
            Fax = obj["Fax"].ToString();
            string gType = obj["Gender"].ToString();
            switch (gType)
            {
                case "Male": Gender = GenderType.Male; break;
                case "Female": Gender = GenderType.Female; break;
                case "Transgender": Gender = GenderType.Transgender; break;
            }
            GivenName = obj["GivenName"].ToString();
            Group = obj["Group"].ToString();
            HomePhone = obj["HomePhone"].ToString();
            HouseNumber = obj["HouseNumber"].ToString();
            HouseNumberAdd = obj["HouseNumberAdd"].ToString();
            Initials = obj["Initials"].ToString();
            Mail = obj["Mail"].ToString();
            MailAlias = obj["MailAlias"].ToString();
            MobilePhone = obj["MobilePhone"].ToString();
            PostalCode = obj["PostalCode"].ToString();
            RegisterID = obj["RegisterID"].ToString();
            switch (obj["Role"].ToString())
            {
                case "IT": Role = AccountRole.IT; break;
                case "Director": Role = AccountRole.Director; break;
                case "Student": Role = AccountRole.Student; break;
                case "Other": Role = AccountRole.Other; break;
                case "Teacher": Role = AccountRole.Teacher; break;
                case "Maintenance": Role = AccountRole.Maintenance; break;
                case "Support": Role = AccountRole.Support; break;
            }
            StemID = Convert.ToInt32(obj["StemID"]);
            Street = obj["Street"].ToString();
            SurName = obj["SurName"].ToString();
            UID = obj["UID"].ToString();
            UntisID = obj["UntisID"].ToString();
            Status = obj.ContainsKey("Status") ? obj["Status"].ToString() : string.Empty;
        }

        public bool Equals(IAccount other)
        {
            if (!AccountID.Equals(other.AccountID))
            {
                Error.AddMessage("Account " + UID + " AccountID: " + AccountID + " is not equal to other: " + other.AccountID);
                return false;
            }

            if (!BirthCountry.Equals(other.BirthCountry))
            {
                Error.AddMessage("Account " + UID + " BirthCountry: " + BirthCountry + " is not equal to other: " + other.BirthCountry);
                return false;
            }

            if (!Birthday.Equals(other.Birthday))
            {
                Error.AddMessage("Account " + UID + " Birthday: " + Birthday + " is not equal to other: " + other.Birthday);
                return false;
            }

            if (!BirthPlace.Equals(other.BirthPlace))
            {
                Error.AddMessage("Account " + UID + " BirthPlace: " + BirthPlace + " is not equal to other: " + other.BirthPlace);
                return false;
            }

            if (!City.Equals(other.City))
            {
                Error.AddMessage("Account " + UID + " City: " + City + " is not equal to other: " + other.City);
                return false;
            }

            if (!Country.Equals(other.Country))
            {
                Error.AddMessage("Account " + UID + " Country: " + Country + " is not equal to other: " + other.Country);
                return false;
            }

            if (!ExtraNames.Equals(other.ExtraNames))
            {
                Error.AddMessage("Account " + UID + " ExtraNames: " + ExtraNames + " is not equal to other: " + other.ExtraNames);
                return false;
            }

            if (!Fax.Equals(other.Fax))
            {
                Error.AddMessage("Account " + UID + " Fax: " + Fax + " is not equal to other: " + other.Fax);
                return false;
            }

            if (!Gender.Equals(other.Gender))
            {
                Error.AddMessage("Account " + UID + " Gender: " + Gender + " is not equal to other: " + other.Gender);
                return false;
            }

            if (!GivenName.Equals(other.GivenName))
            {
                Error.AddMessage("Account " + UID + " GivenName: " + GivenName + " is not equal to other: " + other.GivenName);
                return false;
            }

            if (!Group.Equals(other.Group))
            {
                Error.AddMessage("Account " + UID + " Group: " + Group + " is not equal to other: " + other.Group);
                return false;
            }

            if (!HomePhone.Equals(other.HomePhone))
            {
                Error.AddMessage("Account " + UID + " HomePhone: " + HomePhone + " is not equal to other: " + other.HomePhone);
                return false;
            }

            if (!HouseNumber.Equals(other.HouseNumber))
            {
                Error.AddMessage("Account " + UID + " HouseNumber: " + HouseNumber + " is not equal to other: " + other.HouseNumber);
                return false;
            }

            if (!HouseNumberAdd.Equals(other.HouseNumberAdd))
            {
                Error.AddMessage("Account " + UID + " HouseNumberAdd: " + HouseNumberAdd + " is not equal to other: " + other.HouseNumberAdd);
                return false;
            }

            if (!Initials.Equals(other.Initials))
            {
                Error.AddMessage("Account " + UID + " Initials: " + Initials + " is not equal to other: " + other.Initials);
                return false;
            }

            if (!Mail.Equals(other.Mail))
            {
                Error.AddMessage("Account " + UID + " Mail: " + Mail + " is not equal to other: " + other.Mail);
                return false;
            }

            if (!MailAlias.Equals(other.MailAlias))
            {
                Error.AddMessage("Account " + UID + " MailAlias: " + MailAlias + " is not equal to other: " + other.MailAlias);
                return false;
            }

            if (!MobilePhone.Equals(other.MobilePhone))
            {
                Error.AddMessage("Account " + UID + " MobilePhone: " + MobilePhone + " is not equal to other: " + other.MobilePhone);
                return false;
            }

            if (!PostalCode.Equals(other.PostalCode))
            {
                Error.AddMessage("Account " + UID + " PostalCode: " + PostalCode + " is not equal to other: " + other.PostalCode);
                return false;
            }

            if (!RegisterID.Equals(other.RegisterID))
            {
                Error.AddMessage("Account " + UID + " RegisterID: " + RegisterID + " is not equal to other: " + other.RegisterID);
                return false;
            }

            if (!Role.Equals(other.Role))
            {
                Error.AddMessage("Account " + UID + " Role: " + Role + " is not equal to other: " + other.Role);
                return false;
            }

            if (!StemID.Equals(other.StemID))
            {
                Error.AddMessage("Account " + UID + " StemID: " + StemID + " is not equal to other: " + other.StemID);
                return false;
            }

            if (!Street.Equals(other.Street))
            {
                Error.AddMessage("Account " + UID + " Street: " + Street + " is not equal to other: " + other.Street);
                return false;
            }

            if (!SurName.Equals(other.SurName))
            {
                Error.AddMessage("Account " + UID + " SurName: " + SurName + " is not equal to other: " + other.SurName);
                return false;
            }

            if (!UID.Equals(other.UID))
            {
                Error.AddMessage("Account " + UID + " UID: " + UID + " is not equal to other: " + other.UID);
                return false;
            }

            if (!UntisID.Equals(other.UntisID))
            {
                Error.AddMessage("Account " + UID + " UntisID: " + UntisID + " is not equal to other: " + other.UntisID);
                return false;
            }

            return true;
        }
    }
}
