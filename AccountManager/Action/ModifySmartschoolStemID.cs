using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifySmartschoolStemID : AccountAction 
    {
        public ModifySmartschoolStemID() : base (AccountActionType.ModifySmartschoolStemID,
            "Wijzig het stamboeknummer in smartschool",
            "Het stamboeknummer in Wisa verschilt van dat in Smartschool",
            true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            try
            {
                linkedAccount.smartschoolAccount.StemID = Convert.ToInt32(linkedAccount.wisaAccount.StemID);
            }
            catch (Exception)
            {
                linkedAccount.smartschoolAccount.StemID = 0;
            }
            await AccountApi.Smartschool.AccountManager.Save(linkedAccount.smartschoolAccount, "");
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            int stemID = 0;
            try
            {
                stemID = Convert.ToInt32(account.wisaAccount.StemID);
            }
            catch (Exception)
            {
                stemID = 0;
            }

            if (stemID != account.smartschoolAccount.StemID)
            {
                account.SmartschoolStatusColor = "AlertCircleOutline";
                account.SmartschoolStatusColor = "Orange";
                account.Actions.Add(new ModifySmartschoolStemID());
                account.AccountOK = false;
            }
        }
    }
}
