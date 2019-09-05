using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddAccountToSmartschool : AccountAction
    {
       public AddAccountToSmartschool() : base(
           AccountActionType.AddToSmartschool,
           "Maak een Nieuw Smartschool Account",
           "Voeg een account toe aan Smartschool",
           true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            var wisa = linkedAccount.wisaAccount;
            var directory = linkedAccount.directoryAccount;

            await Add(linkedAccount, wisa, directory);
        }

        public static async Task Add(LinkedAccount linkedAccount, AccountApi.Wisa.Student wisa, AccountApi.Directory.Account directory)
        {
            var ssAccount = new AccountApi.Smartschool.Account();

            ssAccount.UID = directory.UID;
            ssAccount.RegisterID = wisa.StateID;
            try
            {
                ssAccount.StemID = Convert.ToInt32(wisa.StemID);
            }
            catch (Exception)
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
            ssAccount.Mail = directory.UID + "@" + AccountApi.Directory.Connector.AzureDomain;
            ssAccount.MailAlias = directory.MailAlias;


            var result = await AccountApi.Smartschool.AccountManager.Save(ssAccount, "FakeP4ssword");
            if (!result)
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + wisa.FullName);
                return;
            } else
            {

                linkedAccount.smartschoolAccount = ssAccount;
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Added account for " + wisa.FullName);
            }
           

            IGroup classgroup;
            if (wisa.ClassGroup.Contains("ANS") || wisa.ClassGroup.Contains("BNS"))
            {
                classgroup = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            }
            else
            {
                classgroup = AccountApi.Smartschool.GroupManager.Root.Find(wisa.ClassGroup);
            }

            await MoveToSmartschoolClassGroup.Move(linkedAccount, classgroup);
        }
    }
}
