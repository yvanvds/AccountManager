using AccountManager.State.Linked;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifySmartschoolBirthPlace : AccountAction
    {
        public ModifySmartschoolBirthPlace() : base(
            "Wijzig de geboorteplaats in smartschool",
            "De geboorteplaats in Wisa verschilt van die in Smartschool",
            true, true)
        { }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.Smartschool.Account.BirthPlace = linkedAccount.Wisa.Account.PlaceOfBirth;
            await AccountApi.Smartschool.AccountManager.Save(linkedAccount.Smartschool.Account, "").ConfigureAwait(false);
        }

        public static void Evaluate(LinkedAccount account)
        {
            if (!account.Smartschool.Account.BirthPlace.Equals(account.Wisa.Account.PlaceOfBirth, StringComparison.CurrentCulture))
            {
                account.Smartschool.FlagWarning();
                account.Actions.Add(new ModifySmartschoolBirthPlace());
                account.OK = false;
            }
        }
    }
}
