using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifySmartschoolStemID : AccountAction
    {
        public ModifySmartschoolStemID() : base(
            "Wijzig het stamboeknummer in smartschool",
            "Het stamboeknummer in Wisa verschilt van dat in Smartschool",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            try
            {
                linkedAccount.Smartschool.Account.StemID = Convert.ToInt32(value: linkedAccount.Wisa.Account.StemID);
            }
            catch (Exception)
            {
                linkedAccount.Smartschool.Account.StemID = 0;
            }
            await AccountApi.Smartschool.AccountManager.Save(linkedAccount.Smartschool.Account, "").ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            int stemID = 0;
            try
            {
                stemID = Convert.ToInt32(account.Wisa.Account.StemID);
            }
            catch (Exception)
            {
                stemID = 0;
            }

            if (stemID != account.Smartschool.Account.StemID)
            {
                account.Smartschool.FlagWarning();
                account.Actions.Add(new ModifySmartschoolStemID());
                account.OK = false;
            }
        }
    }
}
