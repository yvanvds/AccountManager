using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    public static class AccountManager
    {
        /// <summary>
        /// Saves an account to smartschool. This can be used to create a new user as well as update an
        /// existing user, but the account values must be complete. Also a new password must be provided (but can be empty for existing accounts). There are other methods to do a partial
        /// user update.
        /// </summary>
        /// <param name="account">The account to send to smartschool.</param>
        /// <param name="pw1">The new password for the user.</param>
        /// <param name="pw2">The password for the first co-account. This is optional and will not change the password if empty.</param>
        /// <param name="pw3">The password for the second co-account. This is option ald will not change the password if empty.</param>
        /// <returns>Returns true on success. False when the transaction fails. When false, an error will be logged.</returns>
        public static async Task<bool> Save(IAccount account, string pw1, string pw2 = "", string pw3 = "")
        {
            // first convert values to smartschool format

            // Account role needs to be in string format
            string role = "";
            switch (account.Role)
            {
                case AccountRole.Student: role = "Leerling"; break;
                case AccountRole.Support:
                case AccountRole.IT:
                case AccountRole.Maintenance:
                case AccountRole.Teacher: role = "Leerkracht"; break;
                case AccountRole.Director: role = "Directie"; break;
                default: return false; // other accounts should be no part of smartschool
            }

            // Smartschool gender only has m/f values
            string gender = "f";
            if (account.Gender == GenderType.Male) gender = "m";
            else if (account.Gender == GenderType.Transgender) gender = "f"; // Smartschool only knows about male or female. Hopefully they'll discover the 21st century soon!

            // Birthday needs to be a string (year-month-day)
            string birthday = Utils.DateToString(account.Birthday);

            // stamboeknummer is a string value. If equal to zero, it should be an empty string. If less than 1.000.000, a string needs
            // to be added upfront.
            string stemID = account.StemID.ToString();
            if (account.StemID == 0) stemID = "";
            else if (account.StemID < 1000000) stemID = "0" + stemID;

            // The street address must be passed as one string, but will be split on the server side.
            // Splitting occurs on the last space, to separate the house number.
            // If a / is included after that house number, it will be a buss number.
            string StreetAddress = account.Street;
            if (account.HouseNumber != string.Empty) StreetAddress += " " + account.HouseNumber;
            if (account.HouseNumberAdd != string.Empty) StreetAddress += "/" + account.HouseNumberAdd;

            // add account
            var result = await Task.Run(() => Connector.service.saveUser(
              Connector.password,
              account.AccountID,
              account.UID,
              pw1, pw2, pw3,
              account.GivenName,
              account.SurName,
              account.ExtraNames,
              account.Initials,
              gender,
              birthday,
              account.BirthPlace,
              account.BirthCountry,
              StreetAddress,
              account.PostalCode,
              account.City,
              account.Country,
              account.Mail,
              account.MobilePhone,
              account.HomePhone,
              account.Fax,
              account.RegisterID,
              stemID,
              role,
              account.UntisID
              )
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Load account details from smartschool. The account must have a valid UID to begin with.
        /// All other values will be overwritten.
        /// </summary>
        /// <param name="account">The account to load.</param>
        /// <returns>Returns false when failed. Errors will be added to the log object.</returns>
        public static async Task<bool> Load(IAccount account)
        {
            var result = await Task.Run(
              () => Connector.service.getUserDetails(Connector.password, account.UID)
            );

            try
            {
                JSONAccount details = JsonConvert.DeserializeObject<JSONAccount>(result);
                LoadFromJSON(account, details);
                return true;
            }
            catch (Exception e)
            {
                Error.AddError(e.Message);

                int iResult = Convert.ToInt32(result);
                if (iResult != 0)
                {
                    Error.AddError(iResult);
                    return false;
                }
                return false;
            }
        }

        /// <summary>
        /// Loads all the accounts linked to this group
        /// </summary>
        /// <param name="group">The group for which to load accounts.</param>
        /// <returns>awaitable</returns>
        public static async Task LoadAccounts(IGroup group)
        {
            List<IGroup> list = new List<IGroup>();
            group.GetTreeAsList(list);

            List<Task> TaskList = new List<Task>();

            for (int i = 0; i < list.Count; i++)
            {
                TaskList.Add(list[i].LoadAccounts());
            }
            await Task.Run(
              () => Task.WaitAll(TaskList.ToArray())
            );
        }


        /// <summary>
        /// Sets a new password for this account. Please note that smartschool will require users to pick another password once they've signed in.
        /// </summary>
        /// <param name="account">The account for which to change the password.</param>
        /// <param name="password">The new password.</param>
        /// <param name="type">The account type. This can be the main account, or one of the co-accounts.</param>
        /// <returns></returns>
        public static async Task<bool> SetPassword(IAccount account, string password, AccountType type)
        {
            var result = await Task.Run(
              () => Connector.service.savePassword(Connector.password, account.UID, password, (int)type)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Forces the user (or co-account holder) to change their password next time they log in.
        /// </summary>
        /// <param name="account">The target account</param>
        /// <param name="type">The account type</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> ForcePasswordReset(IAccount account, AccountType type)
        {
            var result = await Task.Run(
              () => Connector.service.forcePasswordReset(Connector.password, account.UID, (int)type)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Unregisters a student from smartschool. This does not delete the account but officially
        /// deactivates it. Should be used when students leave the school during the year.
        /// </summary>
        /// <param name="account"></param>
        /// <param name="dateOfChange"></param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> UnregisterStudent(IAccount account, DateTime dateOfChange)
        {
            string changedate = Utils.DateToString(dateOfChange);

            var result = await Task.Run(() =>
              Connector.service.unregisterStudent(Connector.password, account.UID, changedate)
            );
            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }
            account.Status = "is deactivated";
            Connector.Log.AddMessage(Origin.Smartschool, account.GivenName + " " + account.SurName + " is deactivated");
            return true;
        }

        /// <summary>
        /// Change the account holder's login name(UID). This is done by refering to the AccountID (smartschool internal number) 
        /// </summary>
        /// <param name="account">The target account</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> ChangeUID(IAccount account)
        {
            var result = await Task.Run(
              () => Connector.service.changeUsername(Connector.password, account.AccountID, account.UID)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Change the account holder's internal number (Account ID). This is done by refering to the UID (login name).
        /// </summary>
        /// <param name="account">The target account</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> ChangeAccountID(IAccount account)
        {
            var result = await Task.Run(
              () => Connector.service.changeInternNumber(Connector.password, account.UID, account.AccountID)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Change the status of an account. The status can be active, inactive and administrative.
        /// </summary>
        /// <param name="account">The target account</param>
        /// <param name="state">The desired state</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> SetStatus(IAccount account, AccountState state)
        {
            string status;
            switch (state)
            {
                case AccountState.Active:
                    status = "active";
                    break;
                case AccountState.Inactive:
                    status = "inactive";
                    break;
                case AccountState.Administrative:
                    status = "administrative";
                    break;
                default:
                    status = "invalid";
                    break;
            }

            var result = await Task.Run(
              () => Connector.service.setAccountStatus(Connector.password, account.UID, status)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }

            return true;
        }

        /// <summary>
        /// Get the current account state of the account.
        /// </summary>
        /// <param name="account">The target account</param>
        /// <returns>The current account state</returns>
        public static async Task<AccountState> GetStatus(IAccount account)
        {
            var result = await Task.Run(
              () => Connector.service.getUserDetails(Connector.password, account.UID)
            );

            try
            {
                JSONAccount details = JsonConvert.DeserializeObject<JSONAccount>(result);
                switch (details.Status)
                {
                    case "actief":
                    case "active":
                    case "enabled":
                        return AccountState.Active;
                    case "uitgeschakeld": // yes, this correct. Even though you use inactief, inactive or disabled to set this status!
                        return AccountState.Inactive;
                    case "administrative":
                    case "administratief":
                        return AccountState.Administrative;
                    default:
                        return AccountState.Invalid;
                }

            }
            catch (Exception e)
            {
                Error.AddError(e.Message);

                int iResult = Convert.ToInt32(result);
                if (iResult != 0)
                {
                    Error.AddError(iResult);
                    return AccountState.Invalid;
                }
                return AccountState.Invalid;
            }
        }

        /// <summary>
        /// Delete an account. Important: if the account is assigned to an official class, the official
        /// date of this change should be provided with the overloaded version of this method.
        /// </summary>
        /// <param name="account">The target account.</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> Delete(IAccount account)
        {
            var result = await Delete(account, DateTime.MinValue);
            if (result)
            {
                Connector.Log.AddMessage(Origin.Smartschool, "Account for " + account.GivenName + " " + account.SurName + " Deleted");
            } else
            {
                Connector.Log.AddError(Origin.Smartschool, "Failed to delete " + account.GivenName + " " + account.SurName);
            }
            return result;
        }

        /// <summary>
        /// Delete a (student) account assigned to an official class.
        /// </summary>
        /// <param name="account">The target account</param>
        /// <param name="dateOfChange">The official date of this change.</param>
        /// <returns>awaitable true/false result</returns>
        public static async Task<bool> Delete(IAccount account, DateTime dateOfChange)
        {
            string changeDate = "1-1-1";
            if (dateOfChange != DateTime.MinValue)
            {
                changeDate = Utils.DateToString(dateOfChange);
            }

            var result = await Task.Run(
                () => Connector.service.delUser(Connector.password, account.UID, changeDate)
            );

            int iResult = Convert.ToInt32(result);
            if (iResult != 0)
            {
                Error.AddError(iResult);
                return false;
            }
            return true;
        }

        /// <summary>
        /// Load JSON information retrieved from smartschool into an account. This function is for internal use by the library.
        /// </summary>
        /// <param name="account">The target account</param>
        /// <param name="json">The JSON data to load into this account.</param>
        internal static void LoadFromJSON(IAccount account, JSONAccount json)
        {
            account.UID = json.Gebruikersnaam;
            account.AccountID = json.Internnummer ?? "";
            account.RegisterID = json.Rijksregisternummer;
            try
            {
                account.StemID = Convert.ToInt32(json.Stamboeknummer);
            } catch (Exception)
            {
                // ignore this Connector.Log.AddError(Origin.Smartschool, "Ongeldig stamboeknummer bij account " + json.Gebruikersnaam);
            }
            

            if (json.Basisrol == "1")
            {
                account.Role = AccountRole.Student;
            }
            else if (json.Basisrol == "2")
            {
                account.Role = AccountRole.Teacher;
            }
            else if (json.Basisrol == "3")
            {
                account.Role = AccountRole.Director;
            }

            account.GivenName = json.Voornaam;
            account.SurName = json.Naam;
            account.ExtraNames = json.Extravoornamen;
            account.Initials = json.Initialen;

            if (json.Geslacht.Equals("m"))
            {
                account.Gender = GenderType.Male;
            }
            else if (json.Geslacht.Equals("f"))
            {
                account.Gender = GenderType.Female;
            }
            else
            {
                account.Gender = GenderType.Transgender;
            }

            account.Birthday = Utils.StringToDate(json.Geboortedatum);
            account.BirthPlace = json.Geboorteplaats;
            account.BirthCountry = json.Geboorteland;

            account.Street = json.Straat;
            account.HouseNumber = json.Huisnummer;
            account.HouseNumberAdd = json.Busnummer;
            account.PostalCode = json.Postcode;
            account.City = json.Woonplaats;
            account.Country = json.Land;

            account.MobilePhone = json.Mobielnummer;
            account.HomePhone = json.Telefoonnummer;
            account.Fax = json.Fax;
            account.Mail = json.Emailadres;
            account.Status = json.Status;
        }
    }
}
