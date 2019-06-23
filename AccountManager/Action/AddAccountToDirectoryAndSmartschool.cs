using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddAccountToDirectoryAndSmartschool : AccountAction
    {
        public AddAccountToDirectoryAndSmartschool() : base(
            AccountActionType.AddToDirectoryAndSmartschool,
            "Maak een Nieuw Account",
            "Voeg een account toe aan Active Directory en Smartschool.",
            true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            var wisa = linkedAccount.wisaAccount;
            var account = await AccountApi.Directory.AccountManager.Create(wisa.FirstName, wisa.Name, wisa.WisaID, AccountRole.Student, wisa.ClassGroup);

            var ssAccount = new AccountApi.Smartschool.Account();
            {
                ssAccount.UID = account.UID;
                ssAccount.RegisterID = wisa.StateID;
                try
                {
                    ssAccount.StemID = Convert.ToInt32(wisa.StemID);
                } catch(Exception)
                {
                    ssAccount.StemID = 0;
                }
                
                ssAccount.Role = AccountRole.Student;
                ssAccount.GivenName = wisa.FirstName;
                ssAccount.SurName = wisa.Name;
                ssAccount.Gender = wisa.Gender;
                ssAccount.Birthday = wisa.DateOfBirth;
                ssAccount.BirthPlace = wisa.PlaceOfBirth;
                ssAccount.Street = wisa.Street;
                ssAccount.HouseNumber = wisa.HouseNumber;
                ssAccount.HouseNumberAdd = wisa.HouseNumberAdd;
                ssAccount.PostalCode = wisa.PostalCode;
                ssAccount.City = wisa.City;
                ssAccount.Mail = account.UID + "@" + AccountApi.Directory.Connector.AzureDomain;
                ssAccount.MailAlias = account.MailAlias;
            };

            await AccountApi.Smartschool.AccountManager.Save(ssAccount, "FakeP4ssword");
            IGroup classgroup;
            if (wisa.ClassGroup.Contains("ANS") || wisa.ClassGroup.Contains("BNS"))
            {
                classgroup = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            }
            else
            {
                classgroup = AccountApi.Smartschool.GroupManager.Root.Find(wisa.ClassGroup);
            }

            if (classgroup != null)
                classgroup.Accounts.Add(ssAccount);
        }
    }
}
