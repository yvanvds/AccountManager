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
            "Maak een Nieuw Account",
            "Voeg een account toe aan Active Directory en Smartschool.",
            true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            var wisa = linkedAccount.wisaAccount;
            var account = await AccountApi.Directory.AccountManager.Create(wisa.FirstName, wisa.Name, wisa.WisaID, AccountRole.Student, wisa.ClassGroup);

            var ssAccount = new AccountApi.Smartschool.Account()
            {
                UID = account.UID,
                RegisterID = wisa.StateID,
                StemID = Convert.ToInt32(wisa.StemID),
                Role = AccountRole.Student,
                GivenName = wisa.FirstName,
                SurName = wisa.Name,
                Gender = wisa.Gender,
                Birthday = wisa.DateOfBirth,
                BirthPlace = wisa.PlaceOfBirth,
                Street = wisa.Street,
                HouseNumber = wisa.HouseNumber,
                HouseNumberAdd = wisa.HouseNumberAdd,
                PostalCode = wisa.PostalCode,
                City = wisa.City,
                Mail = account.UID + "@" + AccountApi.Directory.Connector.AzureDomain,
                MailAlias = account.MailAlias,

        };

            await AccountApi.Smartschool.AccountManager.Save(ssAccount, "");
            var classgroup = AccountApi.Smartschool.GroupManager.Root.Find(wisa.ClassGroup);
            if(classgroup != null)
            {
                classgroup.Accounts.Add(ssAccount);
            }
        }
    }
}
