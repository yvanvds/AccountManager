using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class AddToSmartschool : AccountAction
    {
        public AddToSmartschool() : base(
            "Maak een Nieuw Smartschool Account",
            "Voeg een account toe aan Smartschool",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            var wisa = linkedAccount.Wisa.Account;

            await Add(linkedAccount, wisa).ConfigureAwait(false);
        }

        public static async Task Add(State.Linked.LinkedAccount linkedAccount, AccountApi.Wisa.Student wisa)
        {
            var ssAccount = new AccountApi.Smartschool.Account();

            ssAccount.UID = AccountApi.Smartschool.AccountManager.CreateUID(wisa.PreferedName.Length > 0 ? wisa.PreferedName : wisa.FirstName, wisa.Name);
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
            ssAccount.PreferedName = wisa.PreferedName;
            ssAccount.Gender = wisa.Gender;
            ssAccount.Birthday = wisa.DateOfBirth;
            ssAccount.BirthPlace = wisa.PlaceOfBirth;
            ssAccount.Street = wisa.Street;
            ssAccount.HouseNumber = wisa.HouseNumber;
            ssAccount.HouseNumberAdd = wisa.HouseNumberAdd;
            ssAccount.PostalCode = wisa.PostalCode;
            ssAccount.City = wisa.City;
            ssAccount.Mail = linkedAccount.Azure.Account.UserPrincipalName;
            ssAccount.AccountID = wisa.WisaID;

            var result = await AccountApi.Smartschool.AccountManager.Save(ssAccount, "FakeP4ssword").ConfigureAwait(false);
            if (!result)
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + wisa.FullName);
                return;
            }
            else
            {
                AccountApi.Smartschool.GroupManager.UIDs.Add(ssAccount.UID);
                linkedAccount.Smartschool.Account = ssAccount;
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Added account for " + wisa.FullName);
                AccountApi.Smartschool.GroupManager.UIDs.Add(ssAccount.UID);
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

            await MoveToSmartschoolClassGroup.Move(linkedAccount, classgroup).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (account.Wisa.Exists && account.Azure.Exists && !account.Smartschool.Exists)
            {
                account.Actions.Add(new AddToSmartschool());
            }
        }
    }
}
